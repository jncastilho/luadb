local lexer = require("luadb.sql.lexer")

local parser = {}

function parser.parse(sql, params)
    local tokens = lexer.tokenize(sql)
    if #tokens == 0 then
        return nil, "Empty SQL statement"
    end
    local ast = parser._parse_tokens(tokens, sql, params)
    if ast and type(ast) == "table" then
        ast.raw_sql = sql
    end
    return ast
end

function parser._parse_tokens(tokens, sql, params)

    -- Replace ? and $1 placeholders with param values if supplied
    local p_idx = 1
    for i, t in ipairs(tokens) do
        if t.type == "PARAM" then
            local val = nil
            local has_param = false
            if params and p_idx <= #params then
                val = params[p_idx]
                has_param = true
            end
            p_idx = p_idx + 1

            if not has_param then
                val = "luadb"
            end

            if type(val) == "number" then
                tokens[i] = { type = "NUMBER", value = val }
            elseif type(val) == "boolean" then
                tokens[i] = { type = "KEYWORD", value = val and "TRUE" or "FALSE" }
            elseif val == nil then
                tokens[i] = { type = "KEYWORD", value = "NULL" }
            else
                tokens[i] = { type = "STRING", value = tostring(val) }
            end
        end
    end

    local pos = 1

    local function peek() return tokens[pos] end
    local function consume()
        local t = tokens[pos]
        pos = pos + 1
        return t
    end

    local function match_keyword(word)
        local t = peek()
        if t and (t.type == "KEYWORD" or t.type == "IDENTIFIER") and tostring(t.value):upper() == word:upper() then
            return consume()
        end
        return nil
    end

    local function match_symbol(sym)
        local t = peek()
        if t and t.type == "SYMBOL" and t.value == sym then
            return consume()
        end
        return nil
    end

    local function expect_identifier()
        local t = consume()
        if not t or (t.type ~= "IDENTIFIER" and t.type ~= "KEYWORD" and t.type ~= "NUMBER" and t.type ~= "STRING") then
            error("Expected identifier or number, got " .. (t and t.value or "EOF"))
        end
        local val = t.value
        while match_symbol(".") do
            local next_t = consume()
            if next_t then
                val = val .. "." .. next_t.value
            end
        end
        return val
    end

    local function parse_expression()
        local left_ident = expect_identifier()
        local path_keys = {}
        local as_text = false
        local is_json = false
        while peek() and (peek().value == "->" or peek().value == "->>") do
            is_json = true
            local sym = consume().value
            as_text = (sym == "->>")
            local key_tok = consume()
            if not key_tok then error("Expected key after JSON operator " .. sym) end
            table.insert(path_keys, key_tok.value)
        end

        local left_node = is_json and { type = "JSON_EXTRACT", column = left_ident, path = path_keys, as_text = as_text } or left_ident

        -- Check IS NULL / IS NOT NULL
        if match_keyword("IS") then
            local is_not = match_keyword("NOT")
            if match_keyword("NULL") then
                return { left = left_node, op = is_not and "IS NOT NULL" or "IS NULL", right = nil }
            end
        end

        local op_token = consume()
        if not op_token or (op_token.type ~= "OPERATOR" and op_token.type ~= "KEYWORD") then
            error("Expected operator, got " .. (op_token and op_token.value or "EOF"))
        end

        local val_token = consume()
        if not val_token then error("Expected literal value in expression") end

        local expr = {
            left = left_node,
            op = op_token.value:upper(),
            right = val_token.value
        }

        if match_keyword("AND") then
            local next_expr = parse_expression()
            return { type = "AND", left = expr, right = next_expr }
        elseif match_keyword("OR") then
            local next_expr = parse_expression()
            return { type = "OR", left = expr, right = next_expr }
        end

        return expr
    end

    -- ALTER TABLE
    if match_keyword("ALTER") then
        if not match_keyword("TABLE") then error("Expected TABLE after ALTER") end
        local table_name = expect_identifier()
        if match_keyword("ADD") then
            match_keyword("COLUMN") -- optional
            local col_name = expect_identifier()
            local col_type = expect_identifier()
            if match_symbol("(") then
                while peek() and peek().value ~= ")" do consume() end
                match_symbol(")")
            end
            match_symbol(";")
            return { command = "ALTER_ADD_COLUMN", table = table_name, column = col_name, type = col_type }
        elseif match_keyword("RENAME") then
            if not match_keyword("TO") then error("Expected TO after RENAME") end
            local new_name = expect_identifier()
            match_symbol(";")
            return { command = "ALTER_RENAME_TABLE", table = table_name, new_name = new_name }
        end
    end

    -- WITH cte AS (...) SELECT ...
    if match_keyword("WITH") then
        local cte_name = expect_identifier()
        if not match_keyword("AS") then error("Expected AS after CTE name") end
        if not match_symbol("(") then error("Expected '(' before CTE query") end
        
        local inner_tokens = {}
        local depth = 1
        while pos <= #tokens do
            local t = tokens[pos]
            if t.value == "(" then depth = depth + 1
            elseif t.value == ")" then
                depth = depth - 1
                if depth == 0 then
                    pos = pos + 1 -- consume closing ')'
                    break
                end
            end
            table.insert(inner_tokens, t)
            pos = pos + 1
        end

        local main_tokens = {}
        while pos <= #tokens do
            table.insert(main_tokens, tokens[pos])
            pos = pos + 1
        end

        local inner_ast = parser._parse_tokens(inner_tokens)
        local main_ast = parser._parse_tokens(main_tokens)
        main_ast.cte = { name = cte_name, ast = inner_ast }
        return main_ast
    end

    -- 1. CREATE TABLE / CREATE INDEX
    if match_keyword("CREATE") then
        if match_keyword("TABLE") then
            if match_keyword("IF") then
                match_keyword("NOT")
                match_keyword("EXISTS")
            end
            local table_name = expect_identifier()
            if not match_symbol("(") then error("Expected '(' after table name") end

            local columns = {}
            local foreign_keys = {}
            if match_symbol(")") then
                columns = { { name = "id", type = "INTEGER", primary_key = true } }
            else
                repeat
                    if match_keyword("FOREIGN") then
                        match_keyword("KEY")
                        if not match_symbol("(") then error("Expected '(' after FOREIGN KEY") end
                        local fk_col = expect_identifier()
                        if not match_symbol(")") then error("Expected ')' after FOREIGN KEY column") end
                        if not match_keyword("REFERENCES") then error("Expected REFERENCES after FOREIGN KEY definition") end
                        local ref_table = expect_identifier()
                        local ref_col = fk_col
                        if match_symbol("(") then
                            ref_col = expect_identifier()
                            if not match_symbol(")") then error("Expected ')' after REFERENCES column") end
                        end
                        local on_delete = nil
                        if match_keyword("ON") then
                            if match_keyword("DELETE") then
                                if match_keyword("CASCADE") then
                                    on_delete = "CASCADE"
                                end
                            end
                        end
                        table.insert(foreign_keys, { column = fk_col, ref_table = ref_table, ref_column = ref_col, on_delete = on_delete })
                    else
                        local col_name = expect_identifier()
                        local col_type = "TEXT"
                        local peek_tok = peek()
                        if peek_tok and (peek_tok.type == "IDENTIFIER" or peek_tok.type == "KEYWORD") and peek_tok.value:upper() ~= "PRIMARY" and peek_tok.value:upper() ~= "NOT" and peek_tok.value:upper() ~= "NULL" and peek_tok.value:upper() ~= "DEFAULT" and peek_tok.value ~= "," and peek_tok.value ~= ")" then
                            col_type = expect_identifier()
                            if match_symbol("(") then
                                while peek() and peek().value ~= ")" do consume() end
                                match_symbol(")")
                            end
                        end

                        local is_pk = false
                        repeat
                            if match_keyword("PRIMARY") then
                                match_keyword("KEY")
                                is_pk = true
                            elseif match_keyword("NOT") then
                                match_keyword("NULL")
                            elseif match_keyword("NULL") then
                                -- skip
                            elseif match_keyword("DEFAULT") then
                                consume()
                            else
                                break
                            end
                        until false

                        table.insert(columns, { name = col_name, type = col_type, primary_key = is_pk })
                    end

                    if match_symbol(",") then
                        -- continuation
                    elseif match_symbol(")") then
                        break
                    else
                        break
                    end
                until false
            end

            match_symbol(";")
            return { command = "CREATE_TABLE", table = table_name, columns = columns, foreign_keys = foreign_keys }

        elseif match_keyword("INDEX") then
            local idx_name = expect_identifier()
            if not match_keyword("ON") then error("Expected ON after index name") end
            local table_name = expect_identifier()
            if not match_symbol("(") then error("Expected '(' before index column") end
            local col_name = expect_identifier()
            if not match_symbol(")") then error("Expected ')' after index column") end
            match_symbol(";")
            return { command = "CREATE_INDEX", index = idx_name, table = table_name, column = col_name }
        end
    end

    -- REINDEX
    if match_keyword("REINDEX") then
        match_keyword("TABLE")
        match_keyword("DATABASE")
        local target = nil
        local peek_tok = peek()
        if peek_tok and (peek_tok.type == "IDENTIFIER" or peek_tok.type == "STRING") then
            target = expect_identifier()
        end
        match_symbol(";")
        return { command = "REINDEX", target = target }
    end

    -- 2. DROP TABLE / DROP INDEX
    if match_keyword("DROP") then
        if match_keyword("TABLE") then
            local table_name = expect_identifier()
            match_symbol(";")
            return { command = "DROP_TABLE", table = table_name }
        elseif match_keyword("INDEX") then
            local idx_name = expect_identifier()
            match_symbol(";")
            return { command = "DROP_INDEX", index = idx_name }
        end
    end

    -- 3. INSERT INTO
    if match_keyword("INSERT") then
        if not match_keyword("INTO") then error("Expected INTO after INSERT") end
        local table_name = expect_identifier()

        local columns = nil
        if match_symbol("(") then
            columns = {}
            repeat
                table.insert(columns, expect_identifier())
                if not match_symbol(",") then break end
            until false
            if not match_symbol(")") then error("Expected ')' after column list") end
        end

        if not match_keyword("VALUES") then error("Expected VALUES") end
        if not match_symbol("(") then error("Expected '(' before values") end

        local values = {}
        local val_idx = 0
        repeat
            local v = consume()
            if not v or (v.type ~= "STRING" and v.type ~= "NUMBER" and v.type ~= "KEYWORD" and v.type ~= "BOOLEAN") then
                error("Invalid value in INSERT")
            end
            val_idx = val_idx + 1
            local val_to_store = v.value
            local str_val = tostring(v.value):upper()
            if str_val == "TRUE" then val_to_store = true
            elseif str_val == "FALSE" then val_to_store = false
            elseif str_val == "NULL" then val_to_store = nil end
            values[val_idx] = val_to_store  -- Direct index preserves nil holes
            if not match_symbol(",") then break end
        until false
        values.n = val_idx  -- Anchor length so code can determine count including nils

        if not match_symbol(")") then error("Expected ')' after values") end
        match_symbol(";")
        return { command = "INSERT", table = table_name, columns = columns, values = values }
    end

    -- 4. SELECT
    if match_keyword("SELECT") then
        local projections = {}
        if match_symbol("*") then
            projections = { { type = "STAR", value = "*" } }
        else
            repeat
                local agg_type = nil
                if match_keyword("COUNT") then agg_type = "COUNT"
                elseif match_keyword("SUM") then agg_type = "SUM"
                elseif match_keyword("AVG") then agg_type = "AVG"
                elseif match_keyword("MIN") then agg_type = "MIN"
                elseif match_keyword("MAX") then agg_type = "MAX" end

                if agg_type then
                    if not match_symbol("(") then error("Expected '(' after aggregate function") end
                    local target_col = "*"
                    if not match_symbol("*") then
                        target_col = expect_identifier()
                    end
                    if not match_symbol(")") then error("Expected ')' after aggregate target") end
                    table.insert(projections, { type = "AGGREGATE", func = agg_type, column = target_col })
                else
                    local tok = consume()
                    if not tok then error("Unexpected EOF in SELECT projection") end
                    local col_name = tok.value
                    if peek() and peek().value == "." then
                        consume() -- consume '.'
                        if match_symbol("*") then
                            col_name = "*"
                        else
                            local sub_ident = expect_identifier()
                            col_name = sub_ident
                        end
                    elseif match_symbol("*") or (type(col_name) == "string" and col_name:find("%*")) then
                        col_name = "*"
                    elseif match_symbol("(") then
                        local func_args = ""
                        while peek() and peek().value ~= ")" do
                            func_args = func_args .. tostring(consume().value)
                        end
                        match_symbol(")")
                        col_name = col_name .. "(" .. func_args .. ")"
                    end

                    local path_keys = {}
                    local as_text = false
                    local is_json = false
                    while peek() and (peek().value == "->" or peek().value == "->>") do
                        is_json = true
                        local sym = consume().value
                        as_text = (sym == "->>")
                        local key_tok = consume()
                        if not key_tok then error("Expected key after JSON operator " .. sym) end
                        table.insert(path_keys, key_tok.value)
                    end
                    local alias = nil
                    if match_keyword("AS") then alias = expect_identifier() end
                    if is_json then
                        table.insert(projections, {
                            type = "JSON_EXTRACT",
                            column = col_name,
                            path = path_keys,
                            as_text = as_text,
                            alias = alias or (col_name .. (as_text and "->>" or "->") .. table.concat(path_keys, "->"))
                        })
                    else
                        table.insert(projections, { type = (col_name == "*" and "STAR") or ((tok.type == "NUMBER" or tok.type == "STRING") and "LITERAL" or "COLUMN"), column = col_name, alias = alias })
                    end
                end
                if not match_symbol(",") then break end
            until false
        end

        local table_name = nil
        if match_keyword("FROM") then
            table_name = expect_identifier()
            local alias_tok = peek()
            if alias_tok and alias_tok.type == "IDENTIFIER" and alias_tok.value:upper() ~= "WHERE" and alias_tok.value:upper() ~= "JOIN" and alias_tok.value:upper() ~= "ORDER" and alias_tok.value:upper() ~= "LIMIT" then
                consume() -- consume table alias
            end
        end

        local join_clause = nil
        repeat
            if match_keyword("JOIN") or match_keyword("INNER") or match_keyword("LEFT") then
                match_keyword("OUTER")
                match_keyword("JOIN")
                local join_table = expect_identifier()
                local j_alias_tok = peek()
                if j_alias_tok and j_alias_tok.type == "IDENTIFIER" and j_alias_tok.value:upper() ~= "ON" then
                    consume() -- consume join table alias
                end
                if match_keyword("ON") then
                    pcall(parse_expression)
                end
            else
                break
            end
        until false

        local where_clause = nil
        if match_keyword("WHERE") then
            local ok, res = pcall(parse_expression)
            if ok then where_clause = res end
        end

        local group_by = nil
        if match_keyword("GROUP") then
            if match_keyword("BY") then
                local cols = {}
                repeat
                    local tok = consume()
                    if tok then table.insert(cols, tostring(tok.value)) end
                    if not match_symbol(",") then break end
                until false
                group_by = cols
                match_keyword("HAVING") -- optional HAVING clause: consume keyword then expression
                if peek() and peek().value ~= ";" and peek().value:upper() ~= "ORDER" and peek().value:upper() ~= "LIMIT" then
                    pcall(parse_expression)
                end
            end
        end

        local order_by = nil
        if match_keyword("ORDER") then
            if match_keyword("BY") then
                local sort_cols = {}
                repeat
                    local tok = consume()
                    if tok then
                        local col = tok.value
                        local dir = "ASC"
                        if match_keyword("DESC") then dir = "DESC" else match_keyword("ASC") end
                        table.insert(sort_cols, { column = col, direction = dir })
                        if not match_symbol(",") then break end
                    else
                        break
                    end
                until false
                order_by = sort_cols
            end
        end

        local limit = nil
        local offset = nil
        if match_keyword("LIMIT") then
            local lim_tok = consume()
            if lim_tok and lim_tok.type == "NUMBER" then limit = lim_tok.value end
            if match_keyword("OFFSET") then
                local off_tok = consume()
                if off_tok and off_tok.type == "NUMBER" then offset = off_tok.value end
            end
        end

        -- Consume any remaining tokens up to semicolon
        while peek() and peek().value ~= ";" do
            consume()
        end

        match_symbol(";")
        return {
            command = "SELECT",
            projections = projections,
            table = table_name,
            join = join_clause,
            where = where_clause,
            group_by = group_by,
            order_by = order_by,
            limit = limit,
            offset = offset
        }
    end

    -- 5. UPDATE
    if match_keyword("UPDATE") then
        local table_name = expect_identifier()
        if not match_keyword("SET") then error("Expected SET after UPDATE table") end

        local set_assignments = {}
        repeat
            local col = expect_identifier()
            local eq = consume()
            if not eq or (eq.type ~= "OPERATOR" and eq.value ~= "=") then error("Expected '=' in SET") end
            local val = consume()
            table.insert(set_assignments, { column = col, value = val.value })
            if not match_symbol(",") then break end
        until false

        local where_clause = nil
        if match_keyword("WHERE") then
            where_clause = parse_expression()
        end

        match_symbol(";")
        return { command = "UPDATE", table = table_name, assignments = set_assignments, where = where_clause }
    end

    -- 6. DELETE
    if match_keyword("DELETE") then
        if not match_keyword("FROM") then error("Expected FROM after DELETE") end
        local table_name = expect_identifier()

        local where_clause = nil
        if match_keyword("WHERE") then
            where_clause = parse_expression()
        end

        match_symbol(";")
        return { command = "DELETE", table = table_name, where = where_clause }
    end

    -- 7. TRANSACTIONS & SESSION SETTINGS
    if match_keyword("BEGIN") then
        match_keyword("TRANSACTION")
        match_symbol(";")
        return { command = "BEGIN" }
    elseif match_keyword("COMMIT") then
        match_symbol(";")
        return { command = "COMMIT" }
    elseif match_keyword("ROLLBACK") then
        match_symbol(";")
        return { command = "ROLLBACK" }
    end

    local first_val = peek() and tostring(peek().value):upper()
    if first_val == "SHOW" or first_val == "SET" or first_val == "DISCARD" or first_val == "RESET" then
        return { command = "SESSION_SETTING", raw = sql }
    end

    error("Unknown SQL command starting with " .. tostring(peek() and peek().value))
end

return parser
