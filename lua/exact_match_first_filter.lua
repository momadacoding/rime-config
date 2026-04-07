local M = {}

local tone_map = {
    ["ā"] = "a", ["á"] = "a", ["ǎ"] = "a", ["à"] = "a",
    ["ō"] = "o", ["ó"] = "o", ["ǒ"] = "o", ["ò"] = "o",
    ["ē"] = "e", ["é"] = "e", ["ě"] = "e", ["è"] = "e",
    ["ī"] = "i", ["í"] = "i", ["ǐ"] = "i", ["ì"] = "i",
    ["ū"] = "u", ["ú"] = "u", ["ǔ"] = "u", ["ù"] = "u",
    ["ǖ"] = "v", ["ǘ"] = "v", ["ǚ"] = "v", ["ǜ"] = "v",
    ["ü"] = "v",
}

function M.init(env)
    local config = env.engine.schema.config
    env.name_space = env.name_space:gsub('^*', '')
    M.bonus_ratio = tonumber(config:get_string(env.name_space .. '/bonus_ratio')) or 0.35
end

local function normalize_spelling(text)
    if not text or text == "" then
        return ""
    end

    text = text:lower()
    for from, to in pairs(tone_map) do
        text = text:gsub(from, to)
    end

    return text:gsub("[^a-zv]", "")
end

local function boost_quality(cand, ratio)
    local genuine = cand.get_genuine and cand:get_genuine() or cand
    local quality = genuine.quality or cand.quality or 0
    local base = math.max(math.abs(quality), 1.0)
    genuine.quality = quality + base * ratio
    return cand
end

function M.func(input, env)
    local code = normalize_spelling(env.engine.context.input)
    if code == "" then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local items = {}
    local has_exact = false
    local has_fuzzy = false

    for cand in input:iter() do
        local spelling = normalize_spelling(cand.comment)
        local exact = spelling ~= "" and spelling == code
        if exact then
            has_exact = true
        elseif spelling ~= "" then
            has_fuzzy = true
        end

        table.insert(items, {
            cand = cand,
            exact = exact,
        })
    end

    if not (has_exact and has_fuzzy) then
        for _, item in ipairs(items) do
            yield(item.cand)
        end
        return
    end

    for _, item in ipairs(items) do
        if item.exact then
            yield(boost_quality(item.cand, M.bonus_ratio))
        else
            yield(item.cand)
        end
    end
end

return M
