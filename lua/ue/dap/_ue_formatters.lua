-- UE data layouts used by the native fallback. Importing Epic's formatter is
-- the capability probe: a Python package directory is not proof it can load.
local M = {}

function M.commands(engine_root, formatter_path)
  local commands = {}
  local function summary(types, value, regex)
    commands[#commands + 1] = ('type summary add -w UEFallback %s--summary-string "%s" %s')
      :format(regex and '-x ' or '', value, types)
  end
  -- Optional scopes keep NULL storage / absent case-preserving fields from
  -- invalidating the entire summary. ArrayNum is storage, including the NUL.
  summary('FString', 'storage=${var.Data.ArrayNum} data=${var.Data.AllocatorInstance.Data%p}')
  summary('FNameEntryId', '${var.Value}')
  summary('FName', 'index=${var.ComparisonIndex}{ display=${var.DisplayIndex}} Number=${var.Number}')
  summary('FMinimalName', 'index=${var.Index} Number=${var.Number}')
  summary('FVector FIntVector', '(X=${var.X} Y=${var.Y} Z=${var.Z})')
  summary('FVector2D', '(X=${var.X} Y=${var.Y})')
  summary('FVector4 FQuat', '(X=${var.X} Y=${var.Y} Z=${var.Z} W=${var.W})')
  summary('FRotator', '(Pitch=${var.Pitch} Yaw=${var.Yaw} Roll=${var.Roll})')
  summary('FColor FLinearColor', '(R=${var.R} G=${var.G} B=${var.B} A=${var.A})')
  summary('FBox', 'Min=(${var.Min.X},${var.Min.Y},${var.Min.Z}) Max=(${var.Max.X},${var.Max.Y},${var.Max.Z}) Valid=${var.IsValid}')
  summary('"^TArray<.+>$"', 'size=${var.ArrayNum} cap=${var.ArrayMax} data=${var.AllocatorInstance.Data%p}', true)
  -- A sparse array's Num is allocated slots minus free slots, not ArrayNum.
  summary('"^TSet<.+>$"', 'slots=${var.Elements.Data.ArrayNum} free=${var.Elements.NumFreeIndices}', true)
  summary('"^TMap<.+>$"', 'slots=${var.Pairs.Elements.Data.ArrayNum} free=${var.Pairs.Elements.NumFreeIndices}', true)
  summary('UObject UObjectBase UObjectBaseUtility', 'UObject{ name=${var.NamePrivate%S}}{ class=${var.ClassPrivate.NamePrivate%S}}')
  summary('FWeakObjectPtr', 'idx=${var.ObjectIndex} serial=${var.ObjectSerialNumber}')
  summary('"^TWeakObjectPtr<.+>$"', 'idx=${var.ObjectIndex} serial=${var.ObjectSerialNumber}', true)
  summary('"^TSharedPtr<.+>$"', 'obj=${var.Object%p}', true)
  summary('"^TSharedRef<.+>$"', 'obj=${var.Object%p}', true)
  commands[#commands + 1] = 'type category enable UEFallback'

  local path = formatter_path
  if (not path or path == '') and engine_root and engine_root ~= '' then
    path = engine_root .. '/Engine/Extras/LLDBDataFormatters/UE4DataFormatters_2ByteChars.py'
  end
  if path and path ~= '' then
    local file = io.open(path, 'r')
    if file then
      file:close()
      -- K57: never issue bare `script`. The non-fatal import actually tests
      -- bindings/path compatibility; Epic enables its richer category on load.
      commands[#commands + 1] = '?command script import "' .. path:gsub('\\', '/'):gsub('"', '\\"') .. '"'
    end
  end
  return commands
end

return M
