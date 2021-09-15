# This file is part of python-libzim
# (see https://github.com/libzim/python-libzim)
#
# Copyright (c) 2020 Juan Diego Caballero <jdc@monadical.com>
# Copyright (c) 2020 Matthieu Gautier <mgautier@kymeria.fr>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

# Make our libzim module a package by setting a __path__
# There is no real path here, but it will be passed to our module finder.
__path__ = "___LIBZIM___"

cimport zim

import os
import enum
from uuid import UUID
from cpython.ref cimport PyObject
from cpython.buffer cimport PyBUF_WRITABLE
from cython.operator import preincrement
from libc.stdint cimport uint64_t
from libcpp.string cimport string
from libcpp cimport bool
from libcpp.memory cimport shared_ptr
from libcpp.map cimport map
from libcpp.utility cimport move

from typing import Dict, Union
import datetime
import pathlib
import traceback
from types import ModuleType
import sys
import importlib

pybool = type(True)

def create_module(name, doc, members):
    module = ModuleType(name, doc)
    _all = []
    for obj in members:
        if isinstance(obj, tuple):
            name = obj[0]
            obj = obj[1]
        else:
            name = obj.__name__
        setattr(module, name, obj)
        _all.append(name)
    module.__all__ = _all
    sys.modules[name] = module
    return module

###############################################################################
#   Public API to be called from C++ side                                     #
###############################################################################

# This call a python method and return a python object.
cdef object call_method(object obj, string method):
    func = getattr(obj, method.decode('UTF-8'))
    return func()

# Define methods calling a python method and converting the resulting python
# object to the correct cpp type.
# Will be used by cpp side to call python method.
cdef public api:
    string string_cy_call_fct(object obj, string method, string *error) with gil:
        """Lookup and execute a pure virtual method on object returning a string"""
        try:
            ret_str = call_method(obj, method)
            return ret_str.encode('UTF-8')
        except Exception as e:
            error[0] = traceback.format_exc().encode('UTF-8')
        return b""

    zim.Blob blob_cy_call_fct(object obj, string method, string *error) with gil:
        """Lookup and execute a pure virtual method on object returning a Blob"""
        cdef WritingBlob blob

        try:
            blob = call_method(obj, method)
            if blob is None:
                raise RuntimeError("Blob is none")
            return move(blob.c_blob)
        except Exception as e:
            error[0] = traceback.format_exc().encode('UTF-8')

        return move(zim.Blob())

    zim.ContentProvider* contentprovider_cy_call_fct(object obj, string method, string *error) with gil:
        try:
            contentProvider = call_method(obj, method)
            if not contentProvider:
                raise RuntimeError("ContentProvider is None")
            return new zim.ContentProviderWrapper(<PyObject*>contentProvider)
        except Exception as e:
            error[0] = traceback.format_exc().encode('UTF-8')

        return NULL

    # currently have no virtual method returning a bool (was should_index/compress)
    # bool bool_cy_call_fct(object obj, string method, string *error) with gil:
    #     """Lookup and execute a pure virtual method on object returning a bool"""
    #     try:
    #         func = getattr(obj, method.decode('UTF-8'))
    #         return func()
    #     except Exception as e:
    #         error[0] = traceback.format_exc().encode('UTF-8')
    #     return False

    uint64_t int_cy_call_fct(object obj, string method, string *error) with gil:
        """Lookup and execute a pure virtual method on object returning an int"""
        try:
            return <uint64_t> call_method(obj, method)
        except Exception as e:
            error[0] = traceback.format_exc().encode('UTF-8')

        return 0

    map[zim.HintKeys, uint64_t] convertToCppHints(dict hintsDict):
        cdef map[zim.HintKeys, uint64_t] ret;
        for key, value in hintsDict.items():
            ret[key.value] = <uint64_t>value
        return ret

    map[zim.HintKeys, uint64_t] hints_cy_call_fct(object obj, string method, string* error) with gil:
        cdef map[zim.HintKeys, uint64_t] ret;
        try:
            func = getattr(obj, method.decode('UTF-8'))
            hintsDict = {k: pybool(v) for k, v in func().items() if isinstance(k, Hint)}
            return convertToCppHints(hintsDict)
        except Exception as e:
            error[0] = traceback.format_exc().encode('UTF-8')

        return ret


###############################################################################
#   Creator module                                                            #
###############################################################################

writer_module_name = f"{__name__}.writer"

cdef class WritingBlob:
    __module__ = writer_module_name
    cdef zim.Blob c_blob
    cdef bytes ref_content

    def __cinit__(self, content):
        if isinstance(content, str):
            self.ref_content = content.encode('UTF-8')
        else:
            self.ref_content = content
        self.c_blob = move(zim.Blob(<char *> self.ref_content, len(self.ref_content)))

    def size(self):
        return self.c_blob.size()



class Compression(enum.Enum):
    """ Compression algorithms available to create ZIM files """
    __module__ = writer_module_name
    none = zim.CompressionType.zimcompNone
    lzma = zim.CompressionType.zimcompLzma
    zstd = zim.CompressionType.zimcompZstd


class Hint(enum.Enum):
    __module__ = writer_module_name
    COMPRESS = zim.HintKeys.COMPRESS
    FRONT_ARTICLE = zim.HintKeys.FRONT_ARTICLE



cdef class _Creator:
    """ Zim Creator

        Attributes
        ----------
        *c_creator : zim.ZimCreator
            a pointer to the C++ Creator object
        _filename: pathlib.Path
            path to create the ZIM file at
        _started : bool
            flag if the creator has started """
    __module__ = writer_module_name

    cdef zim.ZimCreator c_creator
    cdef object _filename
    cdef object _started

    def __cinit__(self, object filename: pathlib.Path, *args, **kwargs):
        self._filename = pathlib.Path(filename)
        self._started = False
        # fail early if destination is not writable
        parent = self._filename.expanduser().resolve().parent
        if not os.access(parent, mode=os.W_OK, effective_ids=(os.access in os.supports_effective_ids)):
            raise IOError("Unable to write ZIM file at {}".format(self._filename))

    def __init__(self, filename: pathlib.Path):
        """ Constructs a File from full zim file path

            Parameters
            ----------
            filename : pathlib.Path
                Full path to a zim file """
        pass

    def config_verbose(self, bool verbose) -> Creator:
        if self._started:
            raise RuntimeError("ZimCreator started")
        self.c_creator.configVerbose(verbose)
        return self

    def config_compression(self, comptype: Compression) -> Creator:
        if self._started:
            raise RuntimeError("ZimCreator started")
        self.c_creator.configCompression(comptype.value)
        return self

    def config_clustersize(self, int size) -> Creator:
        if self._started:
            raise RuntimeError("ZimCreator started")
        self.c_creator.configClusterSize(size)
        return self

    def config_indexing(self, bool indexing, str language) -> Creator:
        if self._started:
            raise RuntimeError("ZimCreator started")
        self.c_creator.configIndexing(indexing, language.encode('utf8'))
        return self

    def config_nbworkers(self, int nbWorkers) -> Creator:
        if self._started:
            raise RuntimeError("ZimCreator started")
        self.c_creator.configNbWorkers(nbWorkers)
        return self

    def set_mainpath(self, str mainPath) -> Creator:
        self.c_creator.setMainPath(mainPath.encode('utf8'))
        return self

    def add_illustration(self, size: int, content):
        cdef string _content = content
        self.c_creator.addIllustration(size, _content)

#    def set_uuid(self, uuid) -> Creator:
#        self.c_creator.setUuid(uuid)

    def add_item(self, WriterItem not None):
        """ Add an item to the Creator object.

            Parameters
            ----------
            item : WriterItem
                The item to add to the file
            Raises
            ------
                RuntimeError
                    If the ZimCreator was already finalized """
        if not self._started:
            raise RuntimeError("ZimCreator not started")

        # Make a shared pointer to ZimArticleWrapper from the ZimArticle object
        cdef shared_ptr[zim.WriterItem] item = shared_ptr[zim.WriterItem](
            new zim.WriterItemWrapper(<PyObject*>WriterItem));
        with nogil:
            self.c_creator.addItem(item)

    def add_metadata(self, str name, bytes content, str mimetype = "text/plain"):
        if not self._started:
            raise RuntimeError("ZimCreator not started")

        cdef string _name = name.encode('utf8')
        cdef string _content = content
        cdef string _mimetype = mimetype.encode('utf8')
        with nogil:
            self.c_creator.addMetadata(_name, _content, _mimetype)

    def add_redirection(self, str path, str title, str targetPath, dict hints):
        if not self._started:
            raise RuntimeError("ZimCreator not started")

        cdef string _path = path.encode('utf8')
        cdef string _title = title.encode('utf8')
        cdef string _targetPath = targetPath.encode('utf8')
        cdef map[zim.HintKeys, uint64_t] _hints = convertToCppHints(hints)
        with nogil:
            self.c_creator.addRedirection(_path, _title, _targetPath, _hints)

    def __enter__(self):
        cdef string _path = str(self._filename).encode('utf8')
        with nogil:
            self.c_creator.startZimCreation(_path)
        self._started = True
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if True or exc_type is None:
            with nogil:
                self.c_creator.finishZimCreation()
        self._started = False

    @property
    def filename(self):
        return self._filename

class ContentProvider:
    __module__ = writer_module_name
    def __init__(self):
        self.generator = None

    def get_size(self) -> int:
        """Size of get_data's result in bytes"""
        raise NotImplementedError("get_size must be implemented.")

    def feed(self) -> WritingBlob:
        """Blob(s) containing the complete content of the article.
        Must return an empty blob to tell writer no more content has to be written.
        Sum(size(blobs)) must be equals to `self.get_size()`
        """
        if self.generator is None:
            self.generator = self.gen_blob()

        try:
            # We have to keep a ref to _blob to be sure gc do not del it while cpp is
            # using it
            self._blob = next(self.generator)
        except StopIteration:
            self._blob = WritingBlob("")

        return self._blob

    def gen_blob(self):
        """Generator yielding blobs for the content of the article"""
        raise NotImplementedError("gen_blob (ro feed) must be implemented")


class StringProvider(ContentProvider):
    __module__ = writer_module_name
    def __init__(self, content):
        super().__init__()
        self.content = content.encode("UTF-8") if isinstance(content, str) else content

    def get_size(self):
        return len(self.content)

    def gen_blob(self):
        yield WritingBlob(self.content)


class FileProvider(ContentProvider):
    __module__ = writer_module_name
    def __init__(self, filepath):
        super().__init__()
        self.filepath = filepath
        self.size = os.path.getsize(self.filepath)

    def get_size(self):
        return self.size

    def gen_blob(self):
        bsize = 1048576  # 1MiB chunk
        with open(self.filepath, "rb") as fh:
            res = fh.read(bsize)
            while res:
                yield WritingBlob(res)
                res = fh.read(bsize)


class BaseWritingItem:
    """Item stub to override

    Pass a subclass of it to Creator.add_item()"""
    __module__ = writer_module_name

    def __init__(self):
        self._blob = None

    def get_path(self) -> str:
        """Full path of item"""
        raise NotImplementedError("get_path must be implemented.")

    def get_title(self) -> str:
        """Item title. Might be indexed and used in suggestions"""
        raise NotImplementedError("get_title must be implemented.")

    def get_mimetype(self) -> str:
        """MIME-type of the item's content."""
        raise NotImplementedError("get_mimetype must be implemented.")

    def get_contentprovider(self) -> ContentProvider:
        """ContentProvider containing the complete content of the item"""
        raise NotImplementedError("get_contentprovider must be implemented.")

    def get_hints(self) -> Dict[Hint, int]:
        raise NotImplementedError("get_hints must be implemented.")

    def __repr__(self) -> str:
        return (
            f"{self.__class__.__name__}(path={self.get_path()}, "
            f"title={self.get_title()})"
        )


def pascalize(keyword: str):
    """Converts python case to pascal case.
    example: long_description -> LongDescription"""
    return "".join(keyword.title().split("_"))


class Creator(_Creator):
    __module__ = writer_module_name
    def config_compression(self, compression: Compression):
        if not isinstance(compression, Compression):
            compression = getattr(Compression, compression.lower())
        return super().config_compression(compression)

    def add_metadata(
        self, name: str, content: Union[str, bytes, datetime.date, datetime.datetime]
    ):
        name = pascalize(name)
        if name == "Date" and isinstance(content, (datetime.date, datetime.datetime)):
            content = content.strftime("%Y-%m-%d").encode("UTF-8")
        if isinstance(content, str):
            content = content.encode("UTF-8")
        super().add_metadata(name=name, content=content)

    def __repr__(self) -> str:
        return f"Creator(filename={self.filename})"

writer_module_doc = """ libzim writer module
- Creator to create ZIM files
- Item to store ZIM articles metadata
- ContentProvider to store an Item's content
- Blob to store actual content

Usage:
with Creator(pathlib.Path("myfile.zim")) as creator:
    creator.configVerbose(False)
    creator.add_metadata("Name", b"my name")
    # example
    creator.add_item(MyItemSubclass(path, title, mimetype, content)
    creator.setMainPath(path)"""
writer_public_objects = [
    Creator,
    Compression,
    ('Blob', WritingBlob),
    Hint,
    ('Item', BaseWritingItem),
    ContentProvider,
    FileProvider,
    StringProvider,
    pascalize
]
writer = create_module(writer_module_name, writer_module_doc, writer_public_objects)


###############################################################################
#   Reader module                                                             #
###############################################################################

reader_module_name = f"{__name__}.reader"
cdef Py_ssize_t itemsize = 1

cdef class ReadingBlob:
    __module__ = reader_module_name
    cdef zim.Blob c_blob
    cdef Py_ssize_t size
    cdef int view_count

    # Factory functions - Currently Cython can't use classmethods
    @staticmethod
    cdef from_blob(zim.Blob blob):
        """ Creates a python Blob from a C++ Blob (zim::) -> Blob

            Parameters
            ----------
            blob : Blob
                A C++ Entry
            Returns
            ------
            Blob
                Casted blob """
        cdef ReadingBlob rblob = ReadingBlob()
        rblob.c_blob = move(blob)
        rblob.size = rblob.c_blob.size()
        rblob.view_count = 0
        return rblob

    def __dealloc__(self):
        if self.view_count:
            raise RuntimeError("Blob has views")

    def __getbuffer__(self, Py_buffer *buffer, int flags):
        if flags&PyBUF_WRITABLE:
            raise BufferError("Cannot create writable memoryview on readonly data")
        buffer.obj = self
        buffer.buf = <void*>self.c_blob.data()
        buffer.len = self.size
        buffer.readonly = 1
        buffer.format = 'c'
        buffer.internal = NULL                  # see References
        buffer.itemsize = itemsize
        buffer.ndim = 1
        buffer.shape = &self.size
        buffer.strides = &itemsize
        buffer.suboffsets = NULL                # for pointer arrays only

        self.view_count += 1

    def __releasebuffer__(self, Py_buffer *buffer):
        self.view_count -= 1


cdef class Entry:
    """ Entry in a Zim archive

        Attributes
        ----------
        *c_entry : Entry (zim::)
            a pointer to the C++ entry object """
    __module__ = reader_module_name
    cdef zim.Entry c_entry

    # Factory functions - Currently Cython can't use classmethods
    @staticmethod
    cdef from_entry(zim.Entry ent):
        """ Creates a python Entry from a C++ Entry (zim::) -> Entry

            Parameters
            ----------
            ent : Entry
                A C++ Entry
            Returns
            ------
            Entry
                Casted entry """
        cdef Entry entry = Entry()
        entry.c_entry = move(ent)
        return entry

    @property
    def title(self) -> str:
        return self.c_entry.getTitle().decode('UTF-8')

    @property
    def path(self) -> str:
        return self.c_entry.getPath().decode("UTF-8", "strict")

    @property
    def _index(self) -> int:
        return self.c_entry.getIndex()

    @property
    def is_redirect(self) -> bool:
        """ Whether entry is a redirect -> bool """
        return self.c_entry.isRedirect()

    def get_redirect_entry(self) -> Entry:
        cdef zim.Entry entry = move(self.c_entry.getRedirectEntry())
        return Entry.from_entry(move(entry))

    def get_item(self) -> Item:
        cdef zim.Item item = move(self.c_entry.getItem(True))
        return Item.from_item(move(item))

    def __repr__(self):
        return f"{self.__class__.__name__}(url={self.path}, title={self.title})"

cdef class Item:
    """ Item in a Zim archive

        Attributes
        ----------
        *c_entry : Entry (zim::)
            a pointer to the C++ entry object """
    __module__ = reader_module_name
    cdef zim.Item c_item
    cdef ReadingBlob _blob
    cdef bool _haveBlob

    # Factory functions - Currently Cython can't use classmethods
    @staticmethod
    cdef from_item(zim.Item _item):
        """ Creates a python ReadArticle from a C++ Article (zim::) -> ReadArticle

            Parameters
            ----------
            _item : Item
                A C++ Item
            Returns
            ------
            Item
                Casted item """
        cdef Item item = Item()
        item.c_item = move(_item)
        return item

    @property
    def title(self) -> str:
        return self.c_item.getTitle().decode('UTF-8')

    @property
    def path(self) -> str:
        return self.c_item.getPath().decode("UTF-8", "strict")

    @property
    def content(self) -> memoryview:
        if not self._haveBlob:
            self._blob = ReadingBlob.from_blob(move(self.c_item.getData(<int> 0)))
            self._haveBlob = True
        return memoryview(self._blob)

    @property
    def mimetype(self) -> str:
        return self.c_item.getMimetype().decode('UTF-8')

    @property
    def _index(self) -> int:
        return self.c_item.getIndex()

    @property
    def size(self) -> int:
        return self.c_item.getSize()

    def __repr__(self):
        return f"{self.__class__.__name__}(url={self.path}, title={self.title})"


cdef class Archive:
    """ Zim Archive Reader

        Attributes
        ----------
        *c_archive : Archive
            a pointer to a C++ Archive object
        _filename : pathlib.Path
            the file name of the Archive Reader object """

    __module__ = reader_module_name
    cdef zim.Archive c_archive
    cdef object _filename

    def __cinit__(self, object filename: pathlib.Path):
        """ Constructs an Archive from full zim file path

            Parameters
            ----------
            filename : pathlib.Path
                Full path to a zim file """

        self.c_archive = move(zim.Archive(str(filename).encode('UTF-8')))
        self._filename = pathlib.Path(self.c_archive.getFilename().decode("UTF-8", "strict"))

    def __eq__(self, other):
        if Archive not in type(self).mro() or Archive not in type(other).mro():
            return False
        try:
            return self.filename.expanduser().resolve() == other.filename.expanduser().resolve()
        except Exception:
            return False

    @property
    def filename(self) -> pathlib.Path:
        return self._filename

    @property
    def filesize(self) -> int:
        """ total size of ZIM file (or files if split """
        return self.c_archive.getFilesize()

    def has_entry_by_path(self, path: str) -> bool:
        return self.c_archive.hasEntryByPath(<string>path.encode('UTF-8'))

    def get_entry_by_path(self, path: str) -> Entry:
        """ Entry from a path -> Entry

            Parameters
            ----------
            path : str
                The path of the article
            Returns
            -------
            Entry
                The Entry object
            Raises
            ------
                KeyError
                    If an entry with the provided path is not found in the archive """
        cdef zim.Entry entry
        try:
            entry = move(self.c_archive.getEntryByPath(<string>path.encode('UTF-8')))
        except RuntimeError as e:
            raise KeyError(str(e))
        return Entry.from_entry(move(entry))

    def has_entry_by_title(self, title: str) -> bool:
        return self.c_archive.hasEntryByTitle(<string>title.encode('UTF-8'))

    def get_entry_by_title(self, title: str) -> Entry:
        """ Entry from a title -> Entry

            Parameters
            ----------
            title : str
                The title of the article
            Returns
            -------
            Entry
                The first Entry object matching the title
            Raises
            ------
                KeyError
                    If an entry with the provided title is not found in the archive """
        cdef zim.Entry entry
        try:
            entry = move(self.c_archive.getEntryByTitle(<string>title.encode('UTF-8')))
        except RuntimeError as e:
            raise KeyError(str(e))
        return Entry.from_entry(move(entry))

    @property
    def metadata_keys(self):
        """ List[str] of Metadata present in this archive """
        return [key.decode("UTF-8", "strict") for key in self.c_archive.getMetadataKeys()]

    def get_metadata(self, name: str) -> bytes:
        """ A Metadata's content -> bytes

            Parameters
            ----------
            name: str
                name/path of the Metadata Entry
            Returns
            -------
            bytes
                Metadata entry's content. Can be of any type. """
        return bytes(self.c_archive.getMetadata(name.encode('UTF-8')))

    def _get_entry_by_id(self, entry_id: int) -> Entry:
        cdef zim.Entry entry = move(self.c_archive.getEntryByPath(<zim.entry_index_type>entry_id))
        return Entry.from_entry(move(entry))

    @property
    def has_main_entry(self) -> bool:
        return self.c_archive.hasMainEntry()

    @property
    def main_entry(self) -> Entry:
        return Entry.from_entry(move(self.c_archive.getMainEntry()))

    @property
    def uuid(self) -> UUID:
        return UUID(self.c_archive.getUuid().hex())

    @property
    def has_new_namespace_scheme(self) -> bool:
        return self.c_archive.hasNewNamespaceScheme()

    @property
    def is_multipart(self) -> bool:
        return self.c_archive.is_multiPart()

    @property
    def has_fulltext_index(self) -> bool:
        return self.c_archive.hasFulltextIndex()

    @property
    def has_title_index(self) -> bool:
        return self.c_archive.hasTitleIndex()

    @property
    def has_checksum(self) -> str:
        return self.c_archive.hasChecksum()

    @property
    def checksum(self) -> str:
        return self.c_archive.getChecksum().decode("UTF-8", "strict")

    def check(self) -> bool:
        """ whether Archive has a checksum anf file verifies it """
        return self.c_archive.check()

    @property
    def entry_count(self) -> int:
        return self.c_archive.getEntryCount()

    @property
    def all_entry_count(self) -> int:
        return self.c_archive.getAllEntryCount()

    @property
    def article_count(self) -> int:
        return self.c_archive.getArticleCount()

    def get_illustration_sizes(self):
        # FIXME: using static shortcut instead of libzim's
        # cdef set[unsigned int] sizes = self.c_archive.getIllustrationSizes()
        return {48}

    def has_illustration(self, size: int = None) -> bool:
        """ whether Archive has an Illustration metadata for this size """
        if size is not None:
            return self.c_archive.hasIllustration(size)
        return self.c_archive.hasIllustration()

    def get_illustration_item(self, size: int = None) -> Item:
        """ Illustration Metadata Item for this size """
        try:
            if size is not None:
                return Item.from_item(move(self.c_archive.getIllustrationItem(size)))
            return Item.from_item(move(self.c_archive.getIllustrationItem()))
        except RuntimeError as e:
            raise KeyError(str(e))

    def __repr__(self) -> str:
        return f"{self.__class__.__name__}(filename={self.filename})"

reader_module_doc = """ libzim reader module

- Archive to open and read ZIM files
- `Archive` gives access to all `Entry`
- `Entry` gives access to `Item` (content)

Usage:

with Archive(fpath) as zim:
    entry = zim.get_entry_by_path(zim.main_entry.path)
    print(f"Article {entry.title} at {entry.path} is "
          f"{entry.get_item().content.nbytes}b")"""
reader_public_objects = [
    Archive,
    Entry,
    Item,
]
reader = create_module(reader_module_name, reader_module_doc, reader_public_objects)


###############################################################################
#   Search module                                                             #
###############################################################################

search_module_name = f"{__name__}.search"

cdef class Query:
    __module__ = search_module_name
    cdef zim.Query c_query

    def set_query(self, query: str):
        self.c_query.setQuery(query.encode('utf8'))


cdef class SearchResultSet:
    __module__ = search_module_name
    cdef zim.SearchResultSet c_resultset

    @staticmethod
    cdef from_resultset(zim.SearchResultSet _resultset):
        cdef SearchResultSet resultset = SearchResultSet()
        resultset.c_resultset = move(_resultset)
        return resultset

    def __iter__(self):
        cdef zim.SearchIterator current = self.c_resultset.begin()
        cdef zim.SearchIterator end = self.c_resultset.end()
        while current != end:
            yield current.getPath().decode('UTF-8')
            preincrement(current)

cdef class Search:
    __module__ = search_module_name
    cdef zim.Search c_search

    # Factory functions - Currently Cython can't use classmethods
    @staticmethod
    cdef from_search(zim.Search _search):
        """ Creates a python ReadArticle from a C++ Article (zim::) -> ReadArticle

            Parameters
            ----------
            _item : Item
                A C++ Item
            Returns
            ------
            Item
                Casted item """
        cdef Search search = Search()
        search.c_search = move(_search)
        return search

    def getEstimatedMatches(self):
        return self.c_search.getEstimatedMatches()

    def getResults(self, start, count):
        return SearchResultSet.from_resultset(move(self.c_search.getResults(start, count)))


cdef class Searcher:
    """ Zim Archive Searcher

        Attributes
        ----------
        *c_archive : Searcher
            a pointer to a C++ Searcher object
    """
    __module__ = search_module_name

    cdef zim.Searcher c_searcher

    def __cinit__(self, object archive: Archive):
        """ Constructs an Archive from full zim file path

            Parameters
            ----------
            filename : pathlib.Path
                Full path to a zim file """

        self.c_searcher = move(zim.Searcher(archive.c_archive))

    def search(self, object query: Query):
        return Search.from_search(move(self.c_searcher.search(query.c_query)))

search_module_doc = """ libzim search module

- Archive to open and read ZIM files
- `Archive` gives access to all `Entry`
- `Entry` gives access to `Item` (content)

Usage:

archive = Archive(fpath)
searcher = Searcher(archive)
query = Query()
query.setQuery("foo")
search = searcher.search(query)
resultSet = search.getResult(10, 10) # get result from 10 to 20 (10 results)
for path in resultSet:
    print(path)"""
search_public_objects = [
    Searcher,
    Query
]
search = create_module(search_module_name, search_module_doc, search_public_objects)


class ModuleLoader(importlib.abc.Loader):
    # Create our module. Easy, just return the created module
    @staticmethod
    def create_module(spec):
        return {
            'libzim.writer': writer,
            'libzim.reader': reader,
            'libzim.search': search
        }.get(spec.name, None)

    @staticmethod
    def exec_module(module):
        # Nothing to execute for our already existing module.
        # But we need to define exec_module to tell python not use the legacy import system.
        pass

class ModuleFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path, target=None):
        if path != __path__:
            # This is not our problem, let import mechanism continue
            return None
        return importlib.machinery.ModuleSpec(fullname, ModuleLoader)

# register finder for our submodules
sys.meta_path.insert(0, ModuleFinder())

__all__ = ["writer", "reader", "search"]

