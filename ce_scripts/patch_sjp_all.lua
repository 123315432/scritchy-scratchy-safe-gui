openProcess('ScritchyScratchy.exe')
local base = getAddress('GameAssembly.dll')
local r = 'base=0x'..string.format('%X',base)
local p1 = base + 0x4B09EF
r = r..' nop='..string.format('%02X',readBytes(p1,1))
if readBytes(p1,1) ~= 0x90 then writeBytes(p1, 0x90,0x90,0x90,0x90,0x90,0x90) r=r..' NOP_DONE' end
local ca = base + 0x29FCCD0
r = r..' old='..readFloat(ca)
writeFloat(ca, 99999.0)
r = r..' new='..readFloat(ca)
return r
