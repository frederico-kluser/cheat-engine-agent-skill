-- Sonda 4: como resolver simbolos criados por autoAssemble?
local S = '[ENABLE]\nalloc(zz_sym,16)\n[DISABLE]\ndealloc(zz_sym)\n'
local ok, info = autoAssemble(S, false)
local alvo = info and info.allocs and info.allocs.zz_sym and info.allocs.zz_sym.address

local linhas = {}
linhas[#linhas + 1] = 'alloc endereco = ' .. tostring(alvo)

local function tenta(rotulo, fn, arg)
  local o, v = pcall(fn, arg)
  linhas[#linhas + 1] = string.format('%-24s ok=%s v=%s', rotulo, tostring(o), tostring(v))
end

tenta('getAddressSafe(zz_sym)', getAddressSafe, 'zz_sym')
tenta('getAddress(zz_sym)', getAddress, 'zz_sym')
tenta('getNameFromAddress(end)', getNameFromAddress, alvo)

-- registro manual
tenta('registerSymbol(zz_sym, end)', registerSymbol, 'zz_sym', alvo)
tenta('getAddressSafe pos-registro', getAddressSafe, 'zz_sym')
tenta('getAddress pos-registro', getAddress, 'zz_sym')

-- limpeza
pcall(autoAssemble, 'dealloc(zz_sym)\n')
return table.concat(linhas, '\n')
