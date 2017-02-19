--- gedcom.lua  © Dirk Laurie  2017 MIT License like that of Lua 5.3
-- Object-oriented representation of GEDCOM files
-- Lua Version: 5.3 (uses the `utf8` library and new `string` and `table`
--   functions)

assert (utf8 and string and table 
    and string.unpack and utf8.len and table.move, 
    "The module `gedcomtk` needs Lua 5.3")

local help = [[
The module returns a single function, here called `gedcom`, which constructs 
a GEDCOM object, here called `ged`. 
  gedcom = require "gedcomtk"
  ged, msg = gedcom (GEDFILE,MODE) 
`msg` is a message suitable for writing to a log file, or if construction 
failed, an error message (in which case `ged` is nil). GEDFILE is the name 
of an existing GEDCOM file. The optional parameter MODE may be:
  0: Do everything in memory; do not read or write any auxiliary
     files. 
  1: Keep only the index to the file in memory, re-read from disk
     whenever actual contents is needed. Recommended for very large
     GEDCOM files.
  2: Write the index to an auxiliary file as soon as it is known.
  4. Attempt to read an auxiliary file and do some basic validity 
     checks.
  3,5,6,7: Add together any selection of two or three nonzero options.
The auxiliary file is a hidden file in the same directory as GEDFILE.
The default value of MODE is 6.
--
The rest of the discussion assumes the in-core implementation, but since 
the out-of-core implementation is achieved by metatables transparent to the 
programmer, nothing is lost. 

GEDCOM lines at levels 0,1 and 2 are parsed according to the rule that each 
line must have a level number, may have a key, must have a tag, and may have 
data. This is where it stops. At level 3 and deeper, only the level 
number is extracted.

Level 0:
  A GEDCOM file is treated as a concatenation of records.
Level 1: 
  A GEDCOM record is treated as a concatenation of fields.
Level 2:
  A GEDCOM field is treated as a concatenation of items.
Level 3:
  A GEDCOM item is treated as a concatenation of lines.
--]]

--[[ 
Configuration options
--]]

OUT_OF_CORE = 1
WRITE_AUXILIARY_FILE = 2
READ_AUXILIARY_FILE = 4
   
-- declare upvalues for some utilities
local Record, reader, level, tagdata, keytagdata
-- initialize metatables
local GEDCOM = {__name="GEDCOM object"}
local RECORD = {__name="GEDCOM record"}
local FIELD = {__name="GEDCOM field"}
local ITEM = {__name="GEDCOM item"}
local metatable = {[0]=GEDCOM, [1]=RECORD, [2]=FIELD, [3]=ITEM}

--- gedcom (FILENAME[,MODE]) constructs a GEDCOM object
-- default MODE=6
-- OUT_OF_CORE = 1
-- WRITE_AUXILIARY_FILE = 2
-- READ_AUXILIARY_FILE = 4
local gedcom = function(filename,MODE)
  MODE = MODE or 6
  local ged = setmetatable ( {
    filename = filename,
    gedfile = assert(io.open(filename)),
    index = {},
    INDI = {},
    FAM = {},
    first_record = {}, 
    out_of_core = MODE & OUT_OF_CORE > 0,
    write_auxiliary_file = MODE & WRITE_AUXILIARY_FILE > 0,
    read_auxiliary_file = MODE & READ_AUXILIARY_FILE > 0,
    },
    GEDCOM)
  if ged.read_auxiliary_file then 
    ged:_read_aux()     
  end
  ged:read(MODE)
  if not ged.out_of_core then
    ged.gedfile:close()
  end
  if ged.write_auxiliary_file then
    ged:_write_aux()
  end
  return ged
end 

--- Methods of a GEDCOM object

-- The __index metamethod is the Swiss Army knife.
--   ged[k] (retrieved from the GEDCOM file itself)
--   ged.method 
--   ged.I1, ged.F1 etc retrieves keyed record
--   ged.HEAD.CHAR etc at each level is the first tag of that name (memoized)
GEDCOM.__index = function(ged,idx)
  while type(idx)=='string' do  
    local lookup = ged.INDI[idx] or ged.FAM[idx] or ged.first_record[idx]
    if lookup then   -- found in one of the indexes
      local record = rawget(ged,lookup)  -- maybe in-core?
      if record then return record 
      else idx=lookup; break             -- no, try out-of-core
      end
    end
    local rec = rawget(ged,idx)
    if rec then return rec end
    local method = GEDCOM[idx] 
    assert(method or not idx:match"^_","¡No private method "..idx.."!")
    return method
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

GEDCOM._auxname = function(ged)
  local fn, count = ged.filename:lower():gsub("%.ged$",".idx")
  assert(count==1,ged.filename.." does not end in .ged or .GED")
  return fn
end

GEDCOM._read_aux = function(ged)
  local auxfile = io.open(ged:_auxname())
  if auxfile then 
    local index = ged.index
    repeat
      local last = auxfile:read"n"
      index[#index+1] = last
    until not last
  end
end  

GEDCOM._write_aux = function(ged)
  local auxfile = io.open(ged:_auxname(),"w")
  if auxfile then 
    auxfile:write(table.concat(ged.index," ")):close()
  end
end  

-------------------------------------------------------------------

--- Read entire GEDCOM, store index values and if in-core, the
--  records themselves
GEDCOM.read = function(ged)
  local gedfile = ged.gedfile
  local rdr = reader(gedfile)
  local index, firstrec = ged.index, ged.first_record
  local k=0
  repeat
    local rec = Record(rdr)
    if not rec then break end
    k = k + 1
    if index[k] and rec.pos~=index[k] then 
      assert(false,("record #%d: starts at %d but index file expects %d"):
      format(k,rec.pos,index[k]))
    end
    index[k] = rec.pos
    local key, tag = keytagdata(rec.lines[1])
    if tag and ged[tag] then ged[tag][key] = k end
    if not tag then
      tag = tagdata(rec.lines[1])
      firstrec[tag] = firstrec[tag] or k
    end
    if not ged.out_of_core then ged[k] = rec end
  until false
end  

--- Reads one GEDCOM record at level `base` and returns its subrecords
--  as a list and its lines in `record.lines`. 
Record = function(rdr,base)
  base = base or 0
  assert(base<=3,"No subdivision supported past level 3")
  local line,pos = rdr()
  if not line then return end
  assert(level(line)==base,
     "Expected line at level "..base..", got "..line)
  local lines = {line}
  local key, tag, data = keytagdata(line)
  if not key then tag, data = tagdata(line) end
  local record = setmetatable(
    {lines=lines,pos=pos,key=key,tag=tag,data=data}, 
    metatable[base+1]) 
  for line in rdr do
    local lev = tonumber(line:match"%s*%S+") 
    if lev<=base then
      rdr:reread(line)
      break
    end
    table.insert(lines,line)
  end
  if #lines>1 and base<3 then 
    local subrdr = reader(lines,2)
    repeat
      local subrec = Record(subrdr,base+1)
      record[#record+1] = subrec
    until not subrec
  end
  if #lines>0 then return record end
end

--- RECORD and FIELD methods

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

RECORD.__unm = function (record)
  return table.concat(record.lines,"\n")
end

FIELD.__index = RECORD.__index

--- define forward-declared utilities

level = function(line)
assert(type(line)=="string")
  return tonumber(line:match"%s*%S+")
end

tagdata = function(line)
assert(type(line)=="string")
  return line:match"%s*%S+%s+(%S+)%s*(.*)"
end

keytagdata = function(line)
assert(type(line)=="string")
  return line:match"%s*%S+%s+@(%S+)@%s+(%S+)%s*(.*)"
end

--- `reader` object: read lines with reread capability 
--    from file, list or string
-- Usage:
--    rdr = reader(source,position) -- construct the reader
--    for line, pos in rdr do   -- read line if any
--      ...
--      rdr:reread(line)   -- put back (modifed) line for rereading
--      ...
--    end
reader = function(source,linepos)
-- Undocumented feature, provided for debugging: `linepos` can be supplied
-- to bypass the line and position routine constructed by default 
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
      local match = source:sub(linepos or 1):gmatch"()([^\n]+)" 
      linepos = function()
        local pos,line = match()
        return line,pos
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

-- export utilities
GEDCOM.util = {reader=reader, Record=Record,
  level=level, tagdata=tagdata, keytagdata=keytagdata}

-- If module `ihelp` has been preloaded, define `help"GEDCOM"`
local ihelp = package.loaded.ihelp
if ihelp then ihelp("GEDCOM",help)
end

return gedcom
