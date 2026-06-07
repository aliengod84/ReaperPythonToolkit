local json = {}

local ESCAPE = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function encode_string(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
    return ESCAPE[char] or string.format("\\u%04x", char:byte())
  end) .. '"'
end

local function is_array(value)
  local max_index = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false, 0
    end
    if key > max_index then
      max_index = key
    end
  end
  return true, max_index
end

local function encode_value(value)
  local value_type = type(value)
  if value_type == "nil" then
    return "null"
  end
  if value_type == "boolean" or value_type == "number" then
    return tostring(value)
  end
  if value_type == "string" then
    return encode_string(value)
  end
  if value_type ~= "table" then
    error("unsupported type: " .. value_type)
  end
  local array_like, max_index = is_array(value)
  local parts = {}
  if array_like then
    for index = 1, max_index do
      parts[#parts + 1] = encode_value(value[index])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for key, entry in pairs(value) do
    parts[#parts + 1] = encode_string(tostring(key)) .. ":" .. encode_value(entry)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function json.encode(value)
  return encode_value(value)
end

local function skip_ws(source, index)
  while true do
    local char = source:sub(index, index)
    if char ~= " " and char ~= "\n" and char ~= "\r" and char ~= "\t" then
      return index
    end
    index = index + 1
  end
end

local parse_value

local function parse_string(source, index)
  local parts = {}
  index = index + 1
  while index <= #source do
    local char = source:sub(index, index)
    if char == '"' then
      return table.concat(parts), index + 1
    end
    if char ~= "\\" then
      parts[#parts + 1] = char
      index = index + 1
    else
      local escape = source:sub(index + 1, index + 1)
      if escape == '"' or escape == "\\" or escape == "/" then
        parts[#parts + 1] = escape
        index = index + 2
      elseif escape == "b" then
        parts[#parts + 1] = "\b"
        index = index + 2
      elseif escape == "f" then
        parts[#parts + 1] = "\f"
        index = index + 2
      elseif escape == "n" then
        parts[#parts + 1] = "\n"
        index = index + 2
      elseif escape == "r" then
        parts[#parts + 1] = "\r"
        index = index + 2
      elseif escape == "t" then
        parts[#parts + 1] = "\t"
        index = index + 2
      elseif escape == "u" then
        local code = tonumber(source:sub(index + 2, index + 5), 16)
        parts[#parts + 1] = utf8.char(code or 63)
        index = index + 6
      else
        error("invalid escape sequence")
      end
    end
  end
  error("unterminated string")
end

local function parse_number(source, index)
  local start_index = index
  while source:sub(index, index):match("[%d%+%-%e%E%.]") do
    index = index + 1
  end
  local value = tonumber(source:sub(start_index, index - 1))
  if value == nil then
    error("invalid number")
  end
  return value, index
end

local function parse_array(source, index)
  local value = {}
  index = skip_ws(source, index + 1)
  if source:sub(index, index) == "]" then
    return value, index + 1
  end
  while index <= #source do
    local entry
    entry, index = parse_value(source, index)
    value[#value + 1] = entry
    index = skip_ws(source, index)
    local char = source:sub(index, index)
    if char == "]" then
      return value, index + 1
    end
    if char ~= "," then
      error("expected ',' in array")
    end
    index = skip_ws(source, index + 1)
  end
  error("unterminated array")
end

local function parse_object(source, index)
  local value = {}
  index = skip_ws(source, index + 1)
  if source:sub(index, index) == "}" then
    return value, index + 1
  end
  while index <= #source do
    local key
    if source:sub(index, index) ~= '"' then
      error("expected string key")
    end
    key, index = parse_string(source, index)
    index = skip_ws(source, index)
    if source:sub(index, index) ~= ":" then
      error("expected ':' in object")
    end
    index = skip_ws(source, index + 1)
    value[key], index = parse_value(source, index)
    index = skip_ws(source, index)
    local char = source:sub(index, index)
    if char == "}" then
      return value, index + 1
    end
    if char ~= "," then
      error("expected ',' in object")
    end
    index = skip_ws(source, index + 1)
  end
  error("unterminated object")
end

parse_value = function(source, index)
  index = skip_ws(source, index)
  local char = source:sub(index, index)
  if char == '"' then
    return parse_string(source, index)
  end
  if char == "{" then
    return parse_object(source, index)
  end
  if char == "[" then
    return parse_array(source, index)
  end
  if char == "t" and source:sub(index, index + 3) == "true" then
    return true, index + 4
  end
  if char == "f" and source:sub(index, index + 4) == "false" then
    return false, index + 5
  end
  if char == "n" and source:sub(index, index + 3) == "null" then
    return nil, index + 4
  end
  return parse_number(source, index)
end

function json.decode(source)
  local value, index = parse_value(source, 1)
  index = skip_ws(source, index)
  if index <= #source then
    error("trailing characters")
  end
  return value
end

return json
