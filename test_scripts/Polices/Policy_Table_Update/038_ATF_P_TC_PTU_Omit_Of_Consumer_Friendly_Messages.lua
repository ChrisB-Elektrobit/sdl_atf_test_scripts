---------------------------------------------------------------------------------------------
-- Requirement summary:
-- [Policies] Merge: PTU into LocalPT (PTU omits "consumer_friendly_messages" section)
--
-- Description:
-- In case the Updated PT omits "consumer_friendly_messages" section, PoliciesManager must maintain
-- the current "consumer_friendly_messages" section in Local PT.
--
-- Preconditions
-- 1. LPT has non empty 'consumer_friendly_messages', note number of records in messages table
-- 2. Register new app
-- 3. Activate app
-- Steps:
-- 1. Perform PTU with empty data in 'consumer_friendly_messages' section
-- 2. After PTU is finished verify consumer_friendly_messages section in LPT: number of records
--
-- Expected result:
-- Previous version of consumer_friendly_messages section is retained
-- Number of records is not changed
---------------------------------------------------------------------------------------------
--[[ General configuration parameters ]]
config.deviceMAC = "12ca17b49af2289436f303e0166030a21e525d266e209267433801a8fd4071a0"

--[[ Required Shared libraries ]]
local mobileSession = require("mobile_session")
local commonFunctions = require("user_modules/shared_testcases/commonFunctions")
local commonSteps = require("user_modules/shared_testcases/commonSteps")
local testCasesForPolicyTable = require('user_modules/shared_testcases/testCasesForPolicyTable')

--[[ Local Variables ]]
local r_expected
local r_actual
local db_file = config.pathToSDL .. "/" .. commonFunctions:read_parameter_from_smart_device_link_ini("AppStorageFolder") .. "/policy.sqlite"
local policy_file_path = commonFunctions:read_parameter_from_smart_device_link_ini("SystemFilesPath")
local ptu_file = "files/jsons/Policies/Policy_Table_Update/ptu_22734.json"

--[[ Local Functions ]]
local function execute_sqlite_query(file_db, query)
  if not file_db then
    return nil
  end
  local res = {}
  local file = io.popen(table.concat({"sqlite3 ", file_db, " '", query, "'"}), 'r')
  if file then
    for line in file:lines() do
      res[#res + 1] = line
    end
    file:close()
    return res
  else
    return nil
  end
end

local function get_num_records()
  return execute_sqlite_query(db_file, "select count(*) from message")[1]
end

--[[ General Precondition before ATF start ]]
testCasesForPolicyTable:Precondition_updatePolicy_By_overwriting_preloaded_pt("files/jsons/Policies/Policy_Table_Update/preloaded_18192.json")
commonSteps:DeleteLogsFileAndPolicyTable()
testCasesForPolicyTable.Delete_Policy_table_snapshot()

--[[ General Settings for configuration ]]
Test = require("connecttest")
require("user_modules/AppTypes")

--[[ Preconditions ]]
commonFunctions:newTestCasesGroup("Preconditions")

function Test.Precondition_NoteNumOfRecords()
  r_expected = get_num_records()
end

function Test.Precondition_ValidateResultBeforePTU()
  EXPECT_ANY()
  :ValidIf(function(_, _)
      local expected_res = {
            "1|TTS1_AppPermissions|LABEL_AppPermissions|LINE1_AppPermissions|LINE2_AppPermissions|TEXTBODY_AppPermissions|en-us|AppPermissions",
            "2|||LINE1_DataConsent|LINE2_DataConsent|TEXTBODY_DataConsent|en-us|DataConsent" }
      local query = "select id, tts, label, line1, line2, textBody, language_code, message_type_name from message"
      local actual_res = commonFunctions:get_data_policy_sql(config.pathToSDL.."/storage/policy.sqlite", query)
      local is_table_equal = commonFunctions:is_table_equal(expected_res, actual_res)

      if not is_table_equal then
        return false, "\nExpected:\n" .. commonFunctions:convertTableToString(expected_res, 1) .. "\nActual:\n" .. commonFunctions:convertTableToString(actual_res, 1)
      end
      return true
    end)
  :Times(1)
end


function Test:Precondition_ActivateApp()
  local requestId1 = self.hmiConnection:SendRequest("SDL.ActivateApp", { appID = self.applications["Test Application"] })
  EXPECT_HMIRESPONSE(requestId1)
  :Do(function(_, data1)
      if data1.result.isSDLAllowed ~= true then
        local requestId2 = self.hmiConnection:SendRequest("SDL.GetUserFriendlyMessage",
          { language = "EN-US", messageCodes = { "DataConsent" } })
        EXPECT_HMIRESPONSE(requestId2)
        :Do(function(_, _)
            self.hmiConnection:SendNotification("SDL.OnAllowSDLFunctionality",
              { allowed = true, source = "GUI", device = { id = config.deviceMAC, name = "127.0.0.1" } })
            EXPECT_HMICALL("BasicCommunication.ActivateApp")
            :Do(function(_, data2)
                self.hmiConnection:SendResponse(data2.id,"BasicCommunication.ActivateApp", "SUCCESS", { })
              end)
            :Times(1)
          end)
      end
    end)
end

--[[ Test ]]
commonFunctions:newTestCasesGroup("Test")

function Test:TestStep_Perform_PTU_Success()
  local policy_file_name = "PolicyTableUpdate"
  local requestId = self.hmiConnection:SendRequest("SDL.GetURLS", { service = 7 })
  EXPECT_HMIRESPONSE(requestId)
  :Do(function(_, _)
      self.hmiConnection:SendNotification("BasicCommunication.OnSystemRequest", { requestType = "PROPRIETARY", fileName = policy_file_name })
      EXPECT_NOTIFICATION("OnSystemRequest", { requestType = "PROPRIETARY" })
      :Do(function(_, _)
          local corIdSystemRequest = self.mobileSession:SendRPC("SystemRequest", { requestType = "PROPRIETARY", fileName = policy_file_name }, ptu_file)
          EXPECT_HMICALL("BasicCommunication.SystemRequest")
          :Do(function(_, data)
              self.hmiConnection:SendResponse(data.id, "BasicCommunication.SystemRequest", "SUCCESS", { })
              self.hmiConnection:SendNotification("SDL.OnReceivedPolicyUpdate", { policyfile = policy_file_path .. "/" .. policy_file_name })
            end)
          EXPECT_RESPONSE(corIdSystemRequest, { success = true, resultCode = "SUCCESS" })
          :Do(function(_, _)
              requestId = self.hmiConnection:SendRequest("SDL.GetUserFriendlyMessage", { language = "EN-US", messageCodes = { "StatusUpToDate" } })
              EXPECT_HMIRESPONSE(requestId)
            end)
        end)
    end)
end

function Test:TestStep_StartNewMobileSession()
  self.mobileSession2 = mobileSession.MobileSession(self, self.mobileConnection)
  self.mobileSession2:StartService(7)
end

function Test:TestStep_RegisterNewApp()
  EXPECT_HMICALL("BasicCommunication.UpdateAppList")
  :Do(function(_, d)
      self.hmiConnection:SendResponse(d.id, d.method, "SUCCESS", { })
      self.applications = { }
      for _, app in pairs(d.params.applications) do
        self.applications[app.appName] = app.appID
      end
    end)
  local corId = self.mobileSession2:SendRPC("RegisterAppInterface", config.application2.registerAppInterfaceParams)
  self.mobileSession2:ExpectResponse(corId, { success = true, resultCode = "SUCCESS" })
end

function Test:TestStep_ValidateNumberMessages()
  self.mobileSession:ExpectAny()
  :ValidIf(function(_, _)
      r_actual = get_num_records()
      if r_expected ~= r_actual then
        return false, "Expected number of records: " .. r_expected .. ", got: " .. r_actual
      end
      return true
    end)
  :Times(1)
end

function Test.TestStep_ValidateResultAfterPTU()
  EXPECT_ANY()
  :ValidIf(function(_, _)
      local expected_res = {
            "1|TTS1_AppPermissions|LABEL_AppPermissions|LINE1_AppPermissions|LINE2_AppPermissions|TEXTBODY_AppPermissions|en-us|AppPermissions",
            "2|||LINE1_DataConsent|LINE2_DataConsent|TEXTBODY_DataConsent|en-us|DataConsent" }
      local query = "select id, tts, label, line1, line2, textBody, language_code, message_type_name from message"
      local actual_res = commonFunctions:get_data_policy_sql(config.pathToSDL.."/storage/policy.sqlite", query)
      local is_table_equal = commonFunctions:is_table_equal(expected_res, actual_res)

      if not is_table_equal then
        return false, "\nExpected:\n" .. commonFunctions:convertTableToString(expected_res, 1) .. "\nActual:\n" .. commonFunctions:convertTableToString(actual_res, 1)
      end
      return true
    end)
  :Times(1)
end

--[[ Postconditions ]]
commonFunctions:newTestCasesGroup("Postconditions")
testCasesForPolicyTable:Restore_preloaded_pt()
function Test.Postcondition_StopSDL()
  StopSDL()
end

return Test