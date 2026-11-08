-- Sonda 3: tabela-verdade autoAssembleCheck x autoAssemble.
local function resumo(t)
  if type(t) ~= 'table' then return type(t) .. '(' .. tostring(t) .. ')' end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  if t.allocs then
    local nomes = {}
    for k, v in pairs(t.allocs) do nomes[#nomes + 1] = k end
    table.sort(nomes)
    return 'table{allocs=' .. table.concat(nomes, ',') .. '}'
  end
  return 'table(pairs=' .. n .. ')'
end

local function linha(rotulo, script)
  local c1, c2 = autoAssembleCheck(script, true, false)
  local a1, a2 = autoAssemble(script, false)
  local partes = {
    string.format('%-22s', rotulo),
    'check=' .. tostring(c1) .. '/' .. tostring(c2),
    'asm=' .. tostring(a1) .. '/' .. resumo(a2),
  }
  -- limpeza de qualquer alloc que tenha sobrado
  if type(a2) == 'table' and a2.allocs then
    for nome in pairs(a2.allocs) do pcall(autoAssemble, 'dealloc(' .. nome .. ')\n') end
  end
  return table.concat(partes, '  ')
end

local casos = {
  { 'so ENABLE valido',   '[ENABLE]\nalloc(zz_e1,16)\n' },
  { 'so ENABLE invalido', '[ENABLE]\nxisso aqui\n' },
  { 'so ENABLE ident',    '[ENABLE]\nalloc(9zz,16)\n' },
  { 'duas secoes valido', '[ENABLE]\nalloc(zz_e2,16)\n[DISABLE]\ndealloc(zz_e2)\n' },
  { 'duas secoes inval',  '[ENABLE]\nalloc(zz_e3,16)\nxisso aqui\n[DISABLE]\ndealloc(zz_e3)\n' },
  { 'sem secao valido',   'alloc(zz_e4,16)\n' },
  { 'sem secao invalido', 'xisso aqui\n' },
  { 'vazio',              '' },
}

local saida = {}
for _, c in ipairs(casos) do
  saida[#saida + 1] = linha(c[1], c[2])
end

-- limpeza final
for _, n in ipairs({ 'zz_e1', 'zz_e2', 'zz_e3', 'zz_e4', 'zz_e5' }) do
  pcall(autoAssemble, 'dealloc(' .. n .. ')\n')
end

return table.concat(saida, '\n')
