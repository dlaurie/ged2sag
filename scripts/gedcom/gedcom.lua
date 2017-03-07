--- gedcom.lua  © Dirk Laurie  2017 MIT License like that of Lua 5.3
-- Object-oriented representation of GEDCOM files
-- Lua Version: 5.3 (uses the `utf8` library and new `string` and `table`
--   functions)

assert (utf8 and string and table 
    and string.unpack and utf8.len and table.move, 
    "The module `gedcom` needs Lua 5.3")
-- Note on `assert`: it is used to detect programming errors only.
-- Errors in the GEDCOM file are reported in a different way.

--- If the module `ihelp` (available from LuaRocks) is loaded before
--  this one, everything below will be avaiable in an interactive session
--  as `help"GEDCOM"`.
local help = [[
The module returns a single function, here called `gedcom`, which constructs 
a GEDCOM object, here called `ged`, and in addition returns a message, here
called `msg`, suitable for writing to a log file. If construction failed, 
`ged` is nil and the message gives the reason for failure.

    gedcom = require "gedcom"
    ged, msg = gedcom (GEDFILE,MODE) 

GEDFILE is the name of an existing GEDCOM file. The optional parameter 
MODE (whose default value is 6) may be:
  0: Do everything in memory; do not read or write any auxiliary
     files. 
  1: Keep only the index to the file in memory, re-read from disk
     whenever actual contents is needed. Recommended for very large
     GEDCOM files.
  2: Write the index to an auxiliary file as soon as it is known.
  4. Attempt to read an auxiliary file and do some basic validity 
     checks.
  3,5,6,7: Add together any selection of two or three nonzero options.
The auxiliary file is stored in the same directory as GEDFILE. Its name
is constructed from that of GEDFILE by a simple algorithm that is best
understood by looking at an example: `Dirk Laurie.GED` will have auxiliary
file `dirk_laurie.idx`.

The rest of the discussion assumes the in-core implementation, but since 
the out-of-core implementation is achieved by metamethods transparent to 
the programmer, nothing is lost. 

GEDCOM lines up to level 3 are parsed according to the rule that each 
line must have a level number, may have a key, must have a tag, and must have 
data (but the data may be empty). This is where it stops. At level 4 and 
deeper, only the level number is examined.

There are four types of GEDCOM-related objects.

- A GEDCOM _item_ is a table with an entry `line` containing a Level 3 line
from a GEDCOM file, values `tag` and `data`, and perhaps `key`. It may also
have an entry `lines` containing at least one line at level 4 or beyond.

- A GEDCOM _field_ is a table with an entry `line` containing a Level 2 line
from a GEDCOM file, values `tag` and `data`, and perhaps `key`. It may at
entries 1,2,.. contain GEDCOM items.

- A GEDCOM _record_ is a table with an entry `line` containing a Level 1 line
from a GEDCOM file, values `tag` and `data`, and perhaps `key`. It may at
entries 1,2,.. contain GEDCOM fields.

- A GEDCOM _object_ is a table with an entry `line` containing a Level 0 line
from a GEDCOM file, values `tag` and `data`, and perhaps `key`. It may at
entries 1,2,.. contain GEDCOM objects. It also has the following entries:
  filename	The name of the GEDCOM file.
  gedfile	The handle of the GEDCOM file.
  index		The byte offset in the GEDCOM file just before the first
		byte of the Level 0 line with which that entry starts.
  INDI		A table in which each entry is the number of the record 
		defining the individual with that key.
  FAM		A table in which each entry is the number of the record
		defining the family with that key.
  OTHER 	A table in which each entry is the number of the some other
		kind of record with that key.
  firstrec	A table in which each entry is the number of the first 
		record with that tag (unkeyed records only).
  msg           List of messages associated with processing this GEDCOM.
  out_of_core		Boolean options	 
  write_auxiliary_file  extracteded from 
  read_auxiliary_file   the value of MODE
  
Indexing of a GEDCOM object is extended in the following ways:
  1. Keys. Any key occuring in the Level 0 line that defines a record can 
     be used, minus the at-signs, as an index into the GEDCOM object. 
     (This is the purpose of INDI, FAM and OTHER.)
  2. Tags. Any tag in an _unkeyed_ Level 0 record can be used as an index
     into the GEDCOM object, and will retrieve the _first_ unkeyed record 
     bearing that tag.
  3. Methods. Functions stored in the GEDCOM metatable are accessible in
     object-oriented (colon) notation, and all fields stored there are 
     accessible by indexing into the object, except when shadowed.

Indexing of a GEDCOM record or field is extended in the following way:
  1. Tags. Any tag in a field or item can be used as an index into the 
     GEDCOM record or field, and will retrieve the _first_ record bearing 
     that tag. This access is memoized: there will be a key equal to that
     tag in the record after the first access.
  2. Methods, as for GEDCOM objects.

NOTE: Extended indexing is read-only in the sense that you can only replace
     a record via its record number, which can in the case of an object can
     be obtained via INDI, FAM or OTHER. You can however modify its contents.

Some of the utility functions used here are exported in the table `util`
in the GEDCOM metatable. They are documented briefly in the text, and the
help is also available interactively if `ihelp` has been loaded.

See the companion module `gedcomtk` for examples of how this module is used.
--]]

--[[ 
Configuration options, deliberately global
--]]

OUT_OF_CORE = 1
WRITE_AUXILIARY_FILE = 2
READ_AUXILIARY_FILE = 4
   
-- declare some utilities as upvalues
local append, tconcat = table.insert, table.concat
local Record, reader, level, tagdata, keytagdata  -- forward utilities
local _read, _read_aux, _write_aux  -- forward private methods

-- initialize metatables
local GEDCOM = {__name="GEDCOM object"}
local RECORD = {__name="GEDCOM record"}
local FIELD = {__name="GEDCOM field"}
local ITEM = {__name="GEDCOM item"}
local metatable = {[0]=GEDCOM, [1]=RECORD, [2]=FIELD, [3]=ITEM}

-- messaging subsystem

--- Customizable messaging. 
--  Msg = Message(translate) constructs a message container with the 
--    specified translation table.
--  Msg:append (message, ...) appends a parameterized message to the container,
--    constructed as 'message:format(...)'. Before doing so, 'message' is
--    replaced by 'translate[message]' if that is not nil.
--  You can customize individual messages, e.g.
--    Msg.translate["Could not open '%s' for reading"] = "No file %s"
--  or replace the whole 'Msg.translate' with a local table, e.g.
--    Msg.translate = dofile "gedcomtk_ZA.lua"
--  The access to 'translate' is deliberately not raw, allowing you to 
--  exploit its __index metamethod.
local function Message (translate)
  return {
    translate = translate or {};
    append = function(Msg,message,...)
      append(Msg,(Msg.translate[message] or message):format(...))
    end;
    concat = function (Msg)
      return tconcat(Msg,"\n")
    end}
  end

local msg = Message()

--- lines = assemble(object)  
-- Recursive `tostring` for a GEDCOM file, record, field or item 
local function assemble(object)
  local buffer = {object.line}
  if object.lines then 
    buffer[2] = tconcat(object.lines,"\n")
  else 
    for k=1,#object do
      buffer[k+1] = assemble(object[k])
    end
  end
  return tconcat(buffer,"\n")
end

--- gedcom (FILENAME[,MODE]) constructs a GEDCOM object
--  gedcom (nil,UTILITY) returns a utility functioon (see near bottom)
local gedcom = function(filename,MODE)
  if type(filename) ~= 'string' then
    return GEDCOM.util[MODE]
  end
  MODE = MODE or 6
  local gedfile, msg = io.open(filename)
  if not gedfile then return nil, msg end
  local msg = Message()
  msg:append("Reading %s",filename)
  local ged = setmetatable ( {
    filename = filename,
    gedfile = gedfile,
    index = {},
    INDI = {},
    FAM = {},
    OTHER = {},
    firstrec = {}, 
    msg = msg,
    out_of_core = MODE & OUT_OF_CORE > 0,
    write_auxiliary_file = MODE & WRITE_AUXILIARY_FILE > 0,
    read_auxiliary_file = MODE & READ_AUXILIARY_FILE > 0,
    },
    GEDCOM)
  if ged.read_auxiliary_file then 
    _read_aux(ged)     
  end
  _read(ged)
  if not ged.out_of_core then
    ged.gedfile:close()
  end
  if ged.write_auxiliary_file then
    _write_aux(ged)
  end
  return ged, msg:concat()
end 

-- metamethods of a GEDCOM object

-- The __index metamethod is the Swiss Army knife.
--   ged[k] (retrieved from the GEDCOM file itself)
--   ged.method 
--   ged.I1, ged.F1 etc retrieves keyed record
--   ged.HEAD.CHAR etc at each level is the first tag of that name
GEDCOM.__index = function(ged,idx)
  while type(idx)=='string' do  
    local lookup = ged.INDI[idx] or ged.FAM[idx] or ged.OTHER[idx] or
      ged.firstrec[idx]
    if lookup then   -- found in one of the indexes
      local record = rawget(ged,lookup)  -- maybe in-core?
      if record then return record 
      else idx=lookup; break             -- no, try out-of-core
      end
    end
    local rec = rawget(ged,idx)
    if rec then return rec end
    return GEDCOM[idx] 
  end
  if type(idx)=='number' then -- not in memory, read from file
    local index, file = rawget(ged,"index"), rawget(ged,"gedfile") 
    local start = index[idx]
    if not (ged.out_of_core and start) then return end
    file:seek("set",start)
    return Record(reader(file))
  else assert(false,"Invalid key type for GEDCOM object")
  end
end

-- private methods of a GEDCOM object

local _auxname = function(ged)
  local msg = ged.msg
  local fn, count = ged.filename:lower():gsub(" ","_"):gsub("%.ged$",".idx")
  if count==1 then return fn
  else msg:append(ged.filename.." does not end in .ged or .GED")
  end
end

_read_aux = function(ged)
  local auxname, msg = _auxname(ged), ged.msg
  if not auxname then 
    msg:append("  Skipping reading of auxfile")
    return 
  end
  local auxfile = io.open(auxname)
  if auxfile then 
    local index = ged.index
    repeat
      local last = auxfile:read"n"
      index[#index+1] = last
    until not last
    msg:append("Offsets for "..tostring(#index)..
      " records read from `"..auxname.."`")
  else msg:append("Could not read from `"..auxname.."`, skipping.")
  end
end  

_write_aux = function(ged)
  local auxname, msg = _auxname(ged), ged.msg
  if not auxname then 
    msg:append("  Skipping writing of auxfile")
    return 
  end
  local auxfile = io.open(auxname,"w")
  if auxfile then 
    auxfile:write(tconcat(ged.index," ")):close()
    msg:append("Offsets for "..tostring(#ged.index)..
        " records written to `"..auxname.."`")
  else msg:append("Could not write to file `"..auxname.."`, skipping.")
  end
end  

--- Read entire GEDCOM, store index values and if in-core, also store the
--  records themselves
_read = function(ged)
  local gedfile, msg = ged.gedfile, ged.msg
  local rdr = reader(gedfile)
  local index, firstrec = ged.index, ged.firstrec
  local k=0
  repeat
    local rec = Record(rdr)
    if not rec then break end
    k = k + 1
    if index[k] and rec.pos~=index[k] then 
      msg:append(("record #%d: byte offset %d but index file expects %d"):
      format(k,rec.pos,index[k]))
    end
    index[k] = rec.pos
    local key, tag = rec.key, rec.tag
    if key and tag then
      (ged[tag] or ged.OTHER)[key] = k 
    end
    if not key then
      firstrec[tag] = firstrec[tag] or k
    end
    if not ged.out_of_core then ged[k] = rec end
  until false
end  

--- public methods of a GEDCOM object

--- build an index of Level 1 records that have a certain tag. 
--     index = ged:build(tag[,stringkey[,msg]])
--  If 'stringkey' is omitted, you will get
--     index[record[tag].data] = record
--  'stringkey' must be a Lua expression that evaluates to a string when
--  the global environment is `record[tag]`. For example:
--     "data" gives the default behaviour
--     "data:match'[^/]+$'" picks out everything after the last '/'
GEDCOM.build = function(ged,tag,stringkey,msg)
  msg = msg or ged.msg
  local index, success = {}
  for _,record in ipairs(ged) do
    local key = record[tag]
    if not key then goto continue end
    local eval = load("return "..(stringkey or "data"),nil,nil,key)
    if not eval then
      msg:append("Could not compile expression '"..tostring(stringkey).."'") 
      return nil,msg
    end
    success, key = pcall(eval)
    if type(key) ~= "string" then
      msg:append("eval ".." did not return a string")
      goto continue
    end
    if index[key] then
      msg:append("Duplicate value for "..tag..": "..index[key].key..
        ", "..record.key)
    else
      index[key] = record
    end
::continue::
  end
  return index,msg
end 

GEDCOM.sanitize = function(ged)   -- maybe later allow options
  local CHAR = ged.HEAD and ged.HEAD.CHAR
  if not CHAR then
    return nil, "Can't sanitize a file that does not provide HEAD.CHAR"
  end 
  CHAR = CHAR.data 
  if CHAR == "UTF-8" then
    for k,v in ipairs(ged) do
      v:sanitize()
    end
    return true, "sanitizing UTF-8"
  end
end

--------------------

--- object, message = Record(rdr,base)
--  Reads one GEDCOM record at level `base`, getting its input from the
--  reader `rdr` (see `reader`). One return value may be nil, but not both.
--    record = Record(rdr,0)
--    field = Record(rdr,1)
--    item = Record(rdr,2)
--    subitem = Record(rdr,3)
Record = function(rdr,base)
  base = base or 0
  assert(base<=3,"No subdivision supported past level 3")
  local line,pos = rdr()
  if not line then return end
  local msg={append=append}
  if level(line)~=base then
    msg:append("ERROR in GEDCOM input at position "..pos) 
    msg:append("  -- Expected line at level "..base..", got "..line)
  end
  local lines = {}
  local key, tag, data = keytagdata(line)
  if not key then tag, data = tagdata(line) end
  local record = setmetatable(
    {line=line,lines=lines,pos=pos,key=key,tag=tag,data=data,msg=msg}, 
    metatable[base+1]) 
  for line in rdr do
    local lev = tonumber(line:match"%s*%S+") 
    if lev<=base then
      rdr:reread(line)
      break
    end
    append(lines,line)
  end
  if #lines>0 and base<3 then 
    local subrdr = reader(lines)
    repeat
      local subrec = Record(subrdr,base+1)
      record[#record+1] = subrec
    until not subrec
  end
  if #lines==0 or base<3 then record.lines = nil end
  return record
end

--- RECORD, FIELD and ITEM methods

RECORD.__index = function(record,idx)
  if type(idx)=='number' then return nil end
  local method = getmetatable(record)[idx]
  if method then return method end
  for k,field in ipairs(record) do
    if field.tag==idx then
      rawset(record,idx,field)  -- memoize it
      return field
    end
  end
end

RECORD.sanitize = function(record)
  if record.lines then
    ITEM.sanitize(record)
  else for k,v in ipairs(record) do
      RECORD.sanitize(v)
    end
  end
end

ITEM.sanitize = function(item)
  local k=1
  local lines = item.lines
  while k<=#lines do
    local line = lines[k]
    print(line)
    local kosher, treif = utf8.len(line)
    if not kosher then
      print("UTF-8 phase error at position "..treif)
    end
    k = k+1
  end
end

FIELD.__index = RECORD.__index
ITEM.__index = RECORD.__index

--- Undocumented feature: `-ged.HEAD` etc puts together a record, etc.
RECORD.__unm = assemble
FIELD.__unm = assemble
ITEM.__unm = assemble

--- define forward-declared utilities

--- lvl = level(line); may return nil if input invalid
level = function(line)
  assert(type(line)=="string")
  return tonumber(line:match"%s*(%d+)%s%S")
end

--- tag, data = tagdata(line); may return nils if input invalid
tagdata = function(line)
  assert(type(line)=="string")
  return line:match"%s*%d+%s+(%S+)%s*(.*)"
end

--- key, tag, data = keytagdata(line); may return nils if input invalid
keytagdata = function(line)
  assert(type(line)=="string")
  return line:match"%s*%d+%s+@(%S+)@%s+(%S+)%s*(.*)"
end

--- `reader` object: read and reread lines from file, list or string
-- Usage:
--    rdr = reader(source,position) -- construct the reader
--    for line, pos in rdr do   -- read line if any
--      ...
--      rdr:reread(line)   -- put back (possibly modifed) line for rereading
--      ...
--    end
reader = function(source,linepos)
-- Undocumented feature, provided for debugging: if `linepos` is a function,
-- it overrides the line and position routine constructed by default 
  if type(linepos) ~= 'function' then
    assert(not linepos or type(linepos) =='number',
     "bad argument #2 to reader, expected number, got "..type(linepos))
    if io.type(source)=='file' then
      local lines, seek = source:lines(), source:seek("set",linepos or 0)
      linepos = function()
        local pos = source:seek()
        return lines(), pos
      end
    elseif type(source)=='string' then
      local init = linepos or 1
      local match = source:sub(init):gmatch"()([^\n]+)" 
      linepos = function()
        local pos,line = match()
        return line,pos+init-1
      end
    elseif type(source)=='table' then 
      local pos = (linepos or 1)-1
      linepos = function()
        pos = pos+1
        return source[pos],pos
      end
    else 
      assert(false,"no default `linepos` defined for type "..type(source))
    end
  end
----
  return setmetatable ( 
  { line = nil,
    pos = nil,
    reread = function(rdr,line)
      rdr.line = line
    end },
  { __call = function(rdr)
      local line = rdr.line
      if not line then
        line, rdr.pos = linepos()
      end      
      rdr.line = nil
      return line, rdr.pos
    end } )
end

-- Export the utilities and metatables. This package of routines can be 
-- retrieved in its entirety as `ged.util` or invidually via the constructor 
-- as e.g. `gedcom(nil,"Message")`.
GEDCOM.util = {reader=reader, Record=Record, level=level, tagdata=tagdata, 
  keytagdata=keytagdata, assemble=assemble, Message=Message, 
  GEDCOM=GEDCOM, RECORD=RECORD, FIELD=FIELD, ITEM=ITEM}

-- If module `ihelp` has been preloaded, define `help"GEDCOM"`
local ihelp = package.loaded.ihelp
if ihelp then ihelp("GEDCOM",help)
end

return gedcom
