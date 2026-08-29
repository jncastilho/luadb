local lexer = {}

local KEYWORDS = {
    ["SELECT"] = true, ["FROM"] = true, ["WHERE"] = true, ["INSERT"] = true,
    ["INTO"] = true, ["VALUES"] = true, ["UPDATE"] = true, ["SET"] = true,
    ["DELETE"] = true, ["CREATE"] = true, ["TABLE"] = true, ["DROP"] = true,
    ["INDEX"] = true, ["PRIMARY"] = true, ["KEY"] = true, ["INTEGER"] = true,
    ["TEXT"] = true, ["BOOLEAN"] = true, ["REAL"] = true, ["NULL"] = true,
    ["AND"] = true, ["OR"] = true, ["NOT"] = true, ["JOIN"] = true,
    ["INNER"] = true, ["LEFT"] = true, ["ON"] = true, ["GROUP"] = true,
    ["BY"] = true, ["HAVING"] = true, ["ORDER"] = true, ["ASC"] = true,
    ["DESC"] = true, ["LIMIT"] = true, ["OFFSET"] = true, ["BEGIN"] = true,
    ["COMMIT"] = true, ["ROLLBACK"] = true, ["TRANSACTION"] = true,
    ["COUNT"] = true, ["SUM"] = true, ["AVG"] = true, ["MIN"] = true,
    ["MAX"] = true, ["LIKE"] = true, ["IS"] = true, ["IN"] = true, ["AS"] = true,
    ["REINDEX"] = true, ["JSON"] = true, ["JSONB"] = true,
    ["TIMESTAMP"] = true, ["TIMESTAMPTZ"] = true, ["DATE"] = true, ["TIME"] = true,
    ["VARCHAR"] = true, ["CHAR"] = true, ["FLOAT"] = true, ["DOUBLE"] = true,
    ["BIGINT"] = true, ["SMALLINT"] = true, ["SERIAL"] = true, ["BYTEA"] = true, ["BLOB"] = true,
    ["TRUE"] = true, ["FALSE"] = true, ["FOREIGN"] = true, ["REFERENCES"] = true,
    ["ALTER"] = true, ["ADD"] = true, ["RENAME"] = true, ["TO"] = true, ["WITH"] = true, ["CASCADE"] = true
}

function lexer.tokenize(sql)
    local tokens = {}
    local pos = 1
    local len = #sql

    while pos <= len do
        local char = sql:sub(pos, pos)

        -- Skip whitespace
        if char:match("%s") then
            pos = pos + 1
        -- Single line comment --
        elseif char == "-" and sql:sub(pos, pos + 1) == "--" then
            local next_newline = sql:find("\n", pos) or (len + 1)
            pos = next_newline + 1
        -- Parameter placeholder ? or $1, $2
        elseif char == "?" then
            table.insert(tokens, { type = "PARAM", value = "?" })
            pos = pos + 1
        elseif char == "$" and sql:sub(pos + 1, pos + 1):match("%d") then
            local end_pos = pos + 1
            while end_pos <= len and sql:sub(end_pos, end_pos):match("%d") do
                end_pos = end_pos + 1
            end
            table.insert(tokens, { type = "PARAM", value = sql:sub(pos, end_pos - 1) })
            pos = end_pos
        -- String literal 'hello' or quoted identifier "public"
        elseif char == "'" or char == '"' then
            local quote = char
            local end_pos = pos + 1
            while end_pos <= len do
                local ch = sql:sub(end_pos, end_pos)
                if ch == quote then
                    -- Check for doubled quote escape (SQL standard: '' inside strings)
                    if end_pos + 1 <= len and sql:sub(end_pos + 1, end_pos + 1) == quote then
                        end_pos = end_pos + 2
                    else
                        break
                    end
                elseif ch == "\\" and end_pos + 1 <= len then
                    end_pos = end_pos + 2
                else
                    end_pos = end_pos + 1
                end
            end
            -- Build the string value handling both escape styles
            local raw = sql:sub(pos + 1, end_pos - 1)
            local str_val = raw:gsub(quote .. quote, quote):gsub("\\" .. quote, quote)
            local tok_type = (quote == '"') and "IDENTIFIER" or "STRING"
            table.insert(tokens, { type = tok_type, value = str_val })
            pos = end_pos + 1
        -- Numbers
        elseif char:match("%d") or (char == "." and sql:sub(pos + 1, pos + 1):match("%d")) then
            local end_pos = pos
            while end_pos <= len and sql:sub(end_pos, end_pos):match("[%d%.]") do
                end_pos = end_pos + 1
            end
            local num_str = sql:sub(pos, end_pos - 1)
            table.insert(tokens, { type = "NUMBER", value = tonumber(num_str) })
            pos = end_pos
        -- JSON Operators ->> and ->
        elseif char == "-" and sql:sub(pos + 1, pos + 2) == ">>" then
            table.insert(tokens, { type = "SYMBOL", value = "->>" })
            pos = pos + 3
        elseif char == "-" and sql:sub(pos + 1, pos + 1) == ">" then
            table.insert(tokens, { type = "SYMBOL", value = "->" })
            pos = pos + 2
        -- Operators & Punctuation
        elseif char == "," or char == "(" or char == ")" or char == "*" or char == ";" or char == "." or char == "+" or char == "-" or char == "/" or char == "%" then
            table.insert(tokens, { type = "SYMBOL", value = char })
            pos = pos + 1
        elseif char == "=" or char == "<" or char == ">" or char == "!" then
            local op = char
            local next_char = sql:sub(pos + 1, pos + 1)
            if next_char == "=" or (char == "<" and next_char == ">") then
                op = op .. next_char
                pos = pos + 2
            else
                pos = pos + 1
            end
            table.insert(tokens, { type = "OPERATOR", value = op })
        -- Identifiers & Keywords
        elseif char:match("[%a_]") then
            local end_pos = pos
            while end_pos <= len and sql:sub(end_pos, end_pos):match("[%w_]") do
                end_pos = end_pos + 1
            end
            local word = sql:sub(pos, end_pos - 1)
            local upper_word = word:upper()
            if KEYWORDS[upper_word] then
                table.insert(tokens, { type = "KEYWORD", value = upper_word })
            else
                table.insert(tokens, { type = "IDENTIFIER", value = word })
            end
            pos = end_pos
        else
            pos = pos + 1
        end
    end

    return tokens
end

return lexer
