#! /usr/bin/env lua
--- gedrepair.lua  © Dirk Laurie  2017 MIT License like that of Lua 5.3
--  Repair broken GEDCOM files.
--  Lua version: 5.3 (maybe earlier, with compatible utf8.len preloaded)

Usage = [[
Usage:  lua gedrepair.lua < faulty.ged > sanitized.ged

At present there are no options. The program sanitizes files from e.g.
WikiTree and Legacy that give imperfect results under LifeLines.
   (a) UTF-8 files with lines broken in mid-codepoint are fixed
       by prepending the debris from the previous line to the data
       part of the following CONC line.
   (b) Level-0 records other than HEAD and TRLR that have no @KEY@
       are omitted.
   (c) Level-0 INDI records with no name get one composed of GIVN
       and SURN, if available, else a name like 
         "Incognito Anonymous /ZXKQJWX/". 
A record of changes is written to 'gedrepair.log'.
]]
if arg[1] then print(Usage); return end

local logfile
local log = function(message,...)
  logfile = logfile or io.open('gedrepair.log',"w")
  if logfile then logfile:write(message:format(...),"\n")
  end
end

local assert = function(condition,message,params)
  if condition then return end
  log(message,params)
  io.stderr:write(message:format(params),"\n")
  os.exit(-1)
end

assert (string and string.match,"Your Lua must have string.match")
local utf8len = utf8 and utf8.len
assert (utf8len,"Your Lua must have utf8.len")

local lineno = 0

function fixutf8(line,debris)
  if debris then
    local prefix, body = line:match"^(%s*%d%s+CONC%s+)(.*)"
    assert(prefix,"Repair is only possible if the defective line is followed by a CONC line.")
    line = prefix .. debris .. body
    log("Line %s repaired using debris from previous line\n",lineno)
  end
  local kosher, treif = utf8len(line)
  if kosher then return line end
  assert(#line-treif<=2,"Debris longer than 3 bytes cannot be repaired")
  return line:sub(1,treif-1), line:sub(treif)
end
   
function addname(key,SURN,GIVN)
  SURN = SURN or tostring(math.random(0,9999999)):gsub(".",
    function(d) 
      local k=tonumber(d)+1
      return ("QZJXKFHVWY"):sub(k,k) 
    end)
  GIVN = GIVN or "Incognito Anonymous"
  local NAME = ("1 NAME %s /%s/"):format(GIVN,SURN)
  io.write(NAME,"\n")
  log("--- %s: Adding %s",key,NAME)
end
  
-- lexer for one GEDCOM line
local gedcom = function(line)
  local level = line:match"%s*(%d+)%s+"
  if not level then return {} end
  local key, tag, data = line:match"%s*%d+%s+@(%S+)@%s+(%S+)%s*(.*)"
  if not tag then tag, data = line:match"%s*%d+%s+(%S+)%s*(.*)" end
  return {level=tonumber(level), key=key, tag=tag, data=data}
end

local line, debris, discard, HEAD, CHAR, INDI, NAME, KEY, SURN, GIVN
discard = false
INDI = false
math.randomseed(os.time())

for line in io.lines() do
  lineno = lineno+1
  local lex = gedcom(line)
  assert (lex.level,"Standard input seems not to be a valid GEDCOM file.\n"
      ..Usage)
  if lex.level==0 then
    if INDI and not NAME then addname(KEY,SURN,GIVN) end
    INDI = false
    if lex.key and lex.tag == "INDI" then
      INDI = true
      KEY = lex.key
    end
    NAME, SURN, GIVN = false, false, false
    discard = not (lex.tag=="HEAD" or lex.tag=="TRLR" or lex.key)
  end  
  if INDI and lex.level==1 then
    NAME = NAME or lex.tag=='NAME'
    SURN = SURN or (lex.tag=='SURN' and lex.data)
    GIVN = GIVN or (lex.tag=='GIVN' and lex.data)
  end    
  if HEAD then
    if line:match"%s*0%s" then
      assert(CHAR,"The header record did not specify CHAR.")
    end 
  else
    HEAD = line:match"%s*0%s+HEAD"
    assert (HEAD,"Standard input seems not to be a valid GEDCOM file.\n"
      ..Usage)
  end
  if CHAR=='UTF-8' then
    line, debris = fixutf8(line,debris)
  elseif not CHAR then
    CHAR = line:match"%s*1%s+CHAR%s+(%S+)"
    if CHAR then
      assert(CHAR=='UTF-8',"Your GEDCOM file is encoded in %s\n" ..
      "`gedrepair.lua` operates only on UTF-8 GEDCOM files.\n"..
      "You could try `iconv -f CP-1252 -t UTF-8`.", CHAR)
    end
  end
  if discard then
    if lex.level==0 then log"--- discarded level 0 record ---" end
    log(line)
  else
    io.write(line,"\n")
  end
end
      
if logfile then
  logfile:close()
end
