-- SJP Patch v2: nop jackpotsGotten check + nop divss (keep chance=5.0 undivided)
-- + write 99999.0 to .rdata using autoAssemble (handles page protection)
openProcess('ScritchyScratchy.exe')
local base = getAddress('GameAssembly.dll')
local r = 'base=0x'..string.format('%X',base)

-- Patch 1: nop jackpotsGotten check (already done, verify)
local p1 = base + 0x4B09EF
if readBytes(p1,1) ~= 0x90 then
  writeBytes(p1, 0x90,0x90,0x90,0x90,0x90,0x90)
  r = r..' P1=NOP_APPLIED'
else
  r = r..' P1=already_nop'
end

-- Patch 2: write 99999.0 to .rdata constant using autoAssemble
-- 99999.0 = 0x47C34F80 in IEEE754
local ok, err = autoAssemble(string.format([[
GameAssembly.dll+29FCCD0:
db 80 4F C3 47
]]))
if ok then
  r = r..' P2=AA_OK val='..readFloat(base + 0x29FCCD0)
else
  r = r..' P2=AA_FAIL:'..tostring(err)
  -- Fallback: nop the divss instruction instead
  -- divss xmm6,xmm0 at RVA 0x4B0AEE = F3 0F 5E F0 (4 bytes)
  local p3 = base + 0x4B0AEE
  local b = readBytes(p3, 1)
  if b == 0xF3 then
    writeBytes(p3, 0x90, 0x90, 0x90, 0x90)
    r = r..' P3=DIVSS_NOPPED'
  else
    r = r..' P3=MISMATCH_'..string.format('%02X',b)
  end
end

return r
