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

function M.func(input, env)
    local code = normalize_spelling(env.engine.context.input)
    if code == "" then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local exact_cands = {}
    local fuzzy_cands = {}
    local has_exact = false
    local has_fuzzy = false

    for cand in input:iter() do
        local spelling = normalize_spelling(cand.comment)
        if spelling ~= "" and spelling == code then
            has_exact = true
            table.insert(exact_cands, cand)
        else
            if spelling ~= "" then
                has_fuzzy = true
            end
            table.insert(fuzzy_cands, cand)
        end
    end

    if not (has_exact and has_fuzzy) then
        for _, cand in ipairs(exact_cands) do
            yield(cand)
        end
        for _, cand in ipairs(fuzzy_cands) do
            yield(cand)
        end
        return
    end

    for _, cand in ipairs(exact_cands) do
        yield(cand)
    end
    for _, cand in ipairs(fuzzy_cands) do
        yield(cand)
    end
end

return M
