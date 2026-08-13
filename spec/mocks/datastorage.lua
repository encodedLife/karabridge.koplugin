--[[--
A stand-in for KOReader's `datastorage`.

Three directories are all KaraBridge asks it for. Paths are returned as given
and nothing is created on disk: the config path specs are about *which* paths
are tried and in what order, not about whether they exist.

@module spec.mocks.datastorage
]]

local MockDataStorage = {}

MockDataStorage.data_dir = "/tmp/karabridge-test"
MockDataStorage.settings_dir = "/tmp/karabridge-test/settings"
MockDataStorage.full_data_dir = "/tmp/karabridge-test"

function MockDataStorage.getDataDir()
    return MockDataStorage.data_dir
end

function MockDataStorage.getSettingsDir()
    return MockDataStorage.settings_dir
end

function MockDataStorage.getFullDataDir()
    return MockDataStorage.full_data_dir
end

--- Point the mock at a different tree.
-- @tparam string root
function MockDataStorage.setRoot(root)
    MockDataStorage.data_dir = root
    MockDataStorage.full_data_dir = root
    MockDataStorage.settings_dir = root .. "/settings"
end

return MockDataStorage
