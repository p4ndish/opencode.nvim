-- Skills System for PandaVim AI
-- Predefined and custom AI skills

local M = {}

-- Default skills
local default_skills = {
    fix = {
        name = "fix",
        description = "Fix bugs and errors in the code",
        prompt_prefix = "Fix the following code to resolve any bugs or errors:",
        context = { "javascript", "typescript", "python", "go", "php", "rust", "java" },
    },
    refactor = {
        name = "refactor",
        description = "Refactor code for better readability and performance",
        prompt_prefix = "Refactor the following code to improve its structure and performance:",
        context = { "javascript", "typescript", "python", "go", "php", "rust", "java" },
    },
    explain = {
        name = "explain",
        description = "Explain the code in simple terms",
        prompt_prefix = "Explain what the following code does in simple terms:",
        context = { "javascript", "typescript", "python", "go", "php", "rust", "java", "html", "css" },
    },
    test = {
        name = "test",
        description = "Generate tests for the code",
        prompt_prefix = "Generate unit tests for the following code:",
        context = { "javascript", "typescript", "python", "go", "php", "rust" },
    },
    comment = {
        name = "comment",
        description = "Add clear comments to the code",
        prompt_prefix = "Add clear, descriptive comments to the following code:",
        context = { "javascript", "typescript", "python", "go", "php", "rust", "java" },
    },
    optimize = {
        name = "optimize",
        description = "Optimize code for performance",
        prompt_prefix = "Optimize the following code for better performance:",
        context = { "javascript", "typescript", "python", "go", "php", "rust" },
    },
    lint = {
        name = "lint",
        description = "Fix code style issues and linting errors",
        prompt_prefix = "Fix the following code to follow proper linting rules:",
        context = { "javascript", "typescript", "css", "scss", "html" },
    },
    translate = {
        name = "translate",
        description = "Translate code comments to English",
        prompt_prefix = "Translate all comments in the following code to English:",
        context = { "javascript", "typescript", "python", "go", "php", "rust" },
    },
    docs = {
        name = "docs",
        description = "Generate documentation for the code",
        prompt_prefix = "Generate documentation for the following code:",
        context = { "javascript", "typescript", "python", "go", "php", "rust", "java" },
    },
}

-- User-defined custom skills
local custom_skills = {}

--- Register a new skill
-- @param skill table: Skill definition with name, description, prompt_prefix
function M.register_skill(skill)
    if not skill.name then
        vim.notify("Skill must have a name", vim.log.levels.ERROR)
        return
    end
    custom_skills[skill.name] = skill
    vim.notify("Registered skill: " .. skill.name, vim.log.levels.INFO)
end

--- Unregister a skill
-- @param name string: Skill name to remove
function M.unregister_skill(name)
    if custom_skills[name] then
        custom_skills[name] = nil
        vim.notify("Unregistered skill: " .. name, vim.log.levels.INFO)
    end
end

--- Get all skills
-- @return table: All available skills
function M.get_all_skills()
    return vim.tbl_deep_extend("force", default_skills, custom_skills)
end

--- Get skill by name
-- @param name string: Skill name
-- @return table|nil: Skill definition or nil if not found
function M.get_skill(name)
    local all = M.get_all_skills()
    return all[name]
end

--- Get skills filtered by filetype
-- @param filetype string: File type to filter by
-- @return table: Skills that match the filetype
function M.get_skills_by_filetype(filetype)
    local result = {}
    local all = M.get_all_skills()

    for name, skill in pairs(all) do
        if skill.context then
            for _, ft in ipairs(skill.context) do
                if ft == filetype then
                    table.insert(result, skill)
                    break
                end
            end
        end
    end

    return result
end

--- Get default skill for filetype
-- @param filetype string: File type
-- @return table: Default skill for the filetype
function M.get_default_skill(filetype)
    local skills = M.get_skills_by_filetype(filetype)
    if #skills > 0 then
        return skills[1]
    end
    return default_skills.fix
end

--- Build prompt with skill prefix and content
-- @param skill_name string: Skill name
-- @param content string: Code content
-- @return string: Complete prompt
function M.build_prompt(skill_name, content)
    local skill = M.get_skill(skill_name)
    if not skill then
        return content
    end

    return skill.prompt_prefix .. "\n\n" .. content
end

--- List skills for display
-- @return table: Formatted skill list for display
function M.list_skills()
    local all = M.get_all_skills()
    local result = {}

    for name, skill in pairs(all) do
        local context_str = skill.context and table.concat(skill.context, ", ") or "all"
        table.insert(result, string.format("- %s: %s (context: %s)", skill.name, skill.description, context_str))
    end

    return result
end

return M
