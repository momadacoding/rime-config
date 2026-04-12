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
    M.english_bonus_ratio = tonumber(config:get_string(env.name_space .. '/english_bonus_ratio')) or M.bonus_ratio
    M.demote_ratio = tonumber(config:get_string(env.name_space .. '/demote_ratio')) or 0.35
    M.min_length = config:get_int(env.name_space .. '/min_length')
    if not M.min_length or M.min_length <= 0 then
        M.min_length = 4
    end
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

local function normalize_text(text)
    if not text or text == "" then
        return ""
    end
    return text:lower()
end

local function is_alpha_input(text)
    return text and text:match("^[a-z]+$") ~= nil
end

local function is_ascii_word(text)
    return text and text:match("^[A-Za-z][A-Za-z0-9._+-]*$") ~= nil
end

local function boost_quality(cand, ratio)
    local genuine = cand.get_genuine and cand:get_genuine() or cand
    local quality = genuine.quality or cand.quality or 0
    local base = math.max(math.abs(quality), 1.0)
    genuine.quality = quality + base * ratio
    return cand
end

local function demote_quality(cand, ratio)
    local genuine = cand.get_genuine and cand:get_genuine() or cand
    local quality = genuine.quality or cand.quality or 0
    local base = math.max(math.abs(quality), 1.0)
    genuine.quality = quality - base * ratio
    return cand
end

function M.func(input, env)
    local code = normalize_spelling(env.engine.context.input)
    if code == "" or #code < M.min_length or not is_alpha_input(code) then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local original_items = {}
    local english_exact_items = {}
    local chinese_exact_items = {}
    local chinese_fuzzy_items = {}
    local neutral_items = {}
    local has_english_exact = false
    local has_chinese_fuzzy = false

    for cand in input:iter() do
        table.insert(original_items, cand)

        local spelling = normalize_spelling(cand.comment)
        local text = normalize_text(cand.text)
        local english_exact = is_ascii_word(cand.text) and text == code
        local chinese_exact = spelling ~= "" and spelling == code
        local chinese_fuzzy = spelling ~= "" and spelling ~= code

        if english_exact then
            has_english_exact = true
            table.insert(english_exact_items, cand)
        elseif chinese_exact then
            table.insert(chinese_exact_items, cand)
        elseif chinese_fuzzy then
            has_chinese_fuzzy = true
            table.insert(chinese_fuzzy_items, cand)
        else
            table.insert(neutral_items, cand)
        end
    end

    if not (has_english_exact and has_chinese_fuzzy) then
        for _, cand in ipairs(original_items) do
            yield(cand)
        end
        return
    end

    for _, cand in ipairs(english_exact_items) do
        yield(boost_quality(cand, M.english_bonus_ratio))
    end
    for _, cand in ipairs(chinese_exact_items) do
        yield(boost_quality(cand, M.bonus_ratio))
    end
    for _, cand in ipairs(neutral_items) do
        yield(cand)
    end
    for _, cand in ipairs(chinese_fuzzy_items) do
        yield(demote_quality(cand, M.demote_ratio))
    end
end

return M
