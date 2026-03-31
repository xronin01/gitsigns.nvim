--- @diagnostic disable: access-invisible
local helpers = require('test.gs_helpers')

local clear = helpers.clear
local eq = helpers.eq
local exec_lua = helpers.exec_lua
local git = helpers.git
local scratch = helpers.scratch
local setup_test_repo = helpers.setup_test_repo
local write_to_file = helpers.write_to_file

helpers.env()

describe('git', function()
  before_each(function()
    clear()
    helpers.setup_path()
  end)

  it('serializes repo operations across objects in the same repo', function()
    local result = exec_lua(function()
      local async = require('gitsigns.async')
      local Obj = require('gitsigns.git').Obj
      local Repo = require('gitsigns.git.repo')
      local uv = vim.uv or vim.loop ---@diagnostic disable-line: deprecated

      local sleep = async.wrap(2, function(timeout, cb)
        local timer = assert(uv.new_timer())
        timer:start(timeout, 0, cb)
        return timer
      end)

      _G._git_lock_events = {}

      local repo = setmetatable({
        _lock = async.semaphore(1),
      }, { __index = Repo })

      local obj_a = setmetatable({ repo = repo }, { __index = Obj })
      local obj_b = setmetatable({ repo = repo }, { __index = Obj })

      async
        .run(function()
          obj_a:lock(function()
            _G._git_lock_events[#_G._git_lock_events + 1] = 'a_enter'
            sleep(2500)
            _G._git_lock_events[#_G._git_lock_events + 1] = 'a_exit'
          end)
        end)
        :raise_on_error()

      async
        .run(function()
          obj_b:lock(function()
            _G._git_lock_events[#_G._git_lock_events + 1] = 'b_enter'
            sleep(10)
            _G._git_lock_events[#_G._git_lock_events + 1] = 'b_exit'
          end)
        end)
        :raise_on_error()

      vim.wait(4000, function()
        return #_G._git_lock_events == 4
      end, 10, true)

      return {
        events = _G._git_lock_events,
      }
    end)

    eq({ 'a_enter', 'a_exit', 'b_enter', 'b_exit' }, result.events)
  end)

  it('log_rename_status handles spaced filenames', function()
    helpers.git_init_scratch()

    local old_name = scratch .. '/old name.txt'
    local new_name = scratch .. '/new name.txt'

    write_to_file(old_name, { 'test' })
    git('add', old_name)
    git('commit', '-m', 'init commit')
    git('mv', old_name, new_name)
    git('commit', '-m', 'rename file')

    local old_relpath = exec_lua(function(repo_dir)
      local async = require('gitsigns.async')
      local Repo = require('gitsigns.git.repo')

      local repo = assert(async.run(Repo.get, repo_dir):wait(5000))
      return async
        .run(function()
          return repo:log_rename_status('HEAD~1', 'new name.txt')
        end)
        :wait(5000)
    end, scratch)

    eq('old name.txt', old_relpath)
  end)

  it('log_rename_status handles unicode filenames', function()
    helpers.git_init_scratch()

    local old_name = scratch .. '/föobær.txt'
    local new_name = scratch .. '/bår.txt'

    write_to_file(old_name, { 'test' })
    git('add', old_name)
    git('commit', '-m', 'init commit')
    git('mv', old_name, new_name)
    git('commit', '-m', 'rename file')

    local old_relpath = exec_lua(function(repo_dir)
      local async = require('gitsigns.async')
      local Repo = require('gitsigns.git.repo')

      local repo = assert(async.run(Repo.get, repo_dir):wait(5000))
      return async
        .run(function()
          return repo:log_rename_status('HEAD~1', 'bår.txt')
        end)
        :wait(5000)
    end, scratch)

    eq('föobær.txt', old_relpath)
  end)

  it('Repo.get_info normalizes mixed native and unix-style paths', function()
    setup_test_repo()

    local supported = exec_lua(function()
      return vim.fn.has('win32') == 1 and vim.fn.executable('cygpath') == 1
    end)
    if not supported then
      return
    end

    local result = exec_lua(function(root)
      local async = require('gitsigns.async')
      local Repo = require('gitsigns.git.repo')

      --- @param fn function
      --- @param name string
      --- @return integer, any
      local function find_upvalue(fn, name)
        local i = 1
        while true do
          local upname, value = debug.getupvalue(fn, i)
          if not upname then
            error(('missing upvalue: %s'):format(name), 2)
          end
          if upname == name then
            return i, value
          end
          i = i + 1
        end
      end

      --- @param fn function
      --- @param replacements table<string, any>
      --- @param cb fun()
      local function with_upvalues(fn, replacements, cb)
        local original = {} --- @type {index: integer, value: any}[]

        for name, value in pairs(replacements) do
          local index, old_value = find_upvalue(fn, name)
          original[#original + 1] = { index = index, value = old_value }
          debug.setupvalue(fn, index, value)
        end

        local ok, err = xpcall(cb, debug.traceback)

        for i = #original, 1, -1 do
          local entry = original[i]
          debug.setupvalue(fn, entry.index, entry.value)
        end

        if not ok then
          error(err, 0)
        end
      end

      local gitdir = vim.fs.joinpath(root, '.git')
      local unix_root = vim.trim(vim.fn.system({ 'cygpath', '--absolute', '--unix', root }))
      local unix_gitdir = vim.trim(vim.fn.system({ 'cygpath', '--absolute', '--unix', gitdir }))
      local expected_root =
        vim.fs.normalize(vim.trim(vim.fn.system({ 'cygpath', '--absolute', '--mixed', root })))
      local expected_gitdir =
        vim.fs.normalize(vim.trim(vim.fn.system({ 'cygpath', '--absolute', '--mixed', gitdir })))

      local info, err
      with_upvalues(Repo.get_info, {
        check_version = function()
          return true
        end,
        git_command = function()
          return { unix_root, unix_gitdir, 'main' }, nil, 0
        end,
      }, function()
        info, err = async.run(Repo.get_info, root):wait(5000)
      end)

      return {
        err = err or '',
        has_info = info ~= nil,
        toplevel = info and info.toplevel or '',
        gitdir = info and info.gitdir or '',
        detached = info and info.detached or false,
        expected_root = expected_root,
        expected_gitdir = expected_gitdir,
      }
    end, scratch)

    eq('', result.err)
    eq(true, result.has_info)
    eq(result.expected_root, result.toplevel)
    eq(result.expected_gitdir, result.gitdir)
    eq(false, result.detached)
  end)

  it('util.cygpath preserves native paths and converts unix paths', function()
    setup_test_repo()

    local supported = exec_lua(function()
      return vim.fn.has('win32') == 1 and vim.fn.executable('cygpath') == 1
    end)
    if not supported then
      return
    end

    local result = exec_lua(function(root)
      local async = require('gitsigns.async')
      local util = require('gitsigns.util')

      local unix_root = vim.trim(vim.fn.system({ 'cygpath', '--absolute', '--unix', root }))
      local mixed_root = vim.trim(vim.fn.system({ 'cygpath', '--absolute', '--mixed', root }))
      local windows_root =
        vim.trim(vim.fn.system({ 'cygpath', '--absolute', '--windows', unix_root }))

      return {
        native_mixed = async.run(util.cygpath, root, 'mixed'):wait(5000),
        unix_mixed = async.run(util.cygpath, unix_root, 'mixed'):wait(5000),
        unix_windows = async.run(util.cygpath, unix_root, 'windows'):wait(5000),
        expected_native = root,
        expected_mixed = mixed_root,
        expected_windows = windows_root,
      }
    end, scratch)

    eq(result.expected_native, result.native_mixed)
    eq(result.expected_mixed, result.unix_mixed)
    eq(result.expected_windows, result.unix_windows)
  end)

  it('Repo.get_info rejects native dirs outside a unix-style worktree', function()
    setup_test_repo()

    local supported = exec_lua(function()
      return vim.fn.has('win32') == 1 and vim.fn.executable('cygpath') == 1
    end)
    if not supported then
      return
    end

    local result = exec_lua(function(root)
      local async = require('gitsigns.async')
      local Repo = require('gitsigns.git.repo')

      --- @param fn function
      --- @param name string
      --- @return integer, any
      local function find_upvalue(fn, name)
        local i = 1
        while true do
          local upname, value = debug.getupvalue(fn, i)
          if not upname then
            error(('missing upvalue: %s'):format(name), 2)
          end
          if upname == name then
            return i, value
          end
          i = i + 1
        end
      end

      --- @param fn function
      --- @param replacements table<string, any>
      --- @param cb fun()
      local function with_upvalues(fn, replacements, cb)
        local original = {} --- @type {index: integer, value: any}[]

        for name, value in pairs(replacements) do
          local index, old_value = find_upvalue(fn, name)
          original[#original + 1] = { index = index, value = old_value }
          debug.setupvalue(fn, index, value)
        end

        local ok, err = xpcall(cb, debug.traceback)

        for i = #original, 1, -1 do
          local entry = original[i]
          debug.setupvalue(fn, entry.index, entry.value)
        end

        if not ok then
          error(err, 0)
        end
      end

      local outside = vim.fn.tempname()
      assert(vim.fn.mkdir(outside, 'p') == 1)

      local gitdir = vim.fs.joinpath(root, '.git')
      local unix_root = vim.trim(vim.fn.system({ 'cygpath', '--absolute', '--unix', root }))
      local unix_gitdir = vim.trim(vim.fn.system({ 'cygpath', '--absolute', '--unix', gitdir }))

      local info, err
      local ok, perr = pcall(function()
        with_upvalues(Repo.get_info, {
          check_version = function()
            return true
          end,
          git_command = function()
            return { unix_root, unix_gitdir, 'main' }, nil, 0
          end,
        }, function()
          info, err = async.run(Repo.get_info, outside):wait(5000)
        end)
      end)

      vim.fn.delete(outside, 'rf')

      return {
        ok = ok,
        perr = perr or '',
        has_info = info ~= nil,
        err = err or '',
      }
    end, scratch)

    eq(true, result.ok)
    eq('', result.perr)
    eq(false, result.has_info)
    eq('', result.err)
  end)
end)
