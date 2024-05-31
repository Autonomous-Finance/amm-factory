AMM_PROCESS_CODE = require('amm')

PROCESSES_PENDING_INIT = PROCESSES_PENDING_INIT or {}
PROCESSES_INITIALIZED = PROCESSES_INITIALIZED or {}
MESSAGE_TO_PROCESS_MAPPING = {}
DEPLOYER_TO_LATEST_PROCESS_MAPPING = {}

Handlers.add(
  "SpawnAMM",
  Handlers.utils.hasMatchingTag("Action", "Spawn-AMM"),
  function (msg)
    local name = msg.Tags.Name
    local tokenA = msg.Tags['Token-A']
    local tokenB = msg.Tags['Token-B']

    ao.spawn(ao.env.Module.Id, {
        Data = "",
        Tags = {
            Name = name,
            ['Token-A'] = tokenA,
            ['Token-B'] = tokenB,
            ['Deployer'] = msg.From,
            ['Original-Message-Id'] = msg.Id,
        }
    })

    ao.send({Target = msg.From, Action = "AMM-Spawned", ['Original-Message-Id'] = msg.Id})
  end
)

Handlers.add(
    "NotifySpawn",
    Handlers.utils.hasMatchingTag("Action", "Spawned"),
    function (msg)
      print(msg)
      local processId = msg.Tags['AO-Spawn-Success']
      local originalMessageId = msg.Tags['Original-Message-Id']
      local deployer = msg.Tags['Deployer']
      table.insert(PROCESSES_PENDING_INIT, processId)
      MESSAGE_TO_PROCESS_MAPPING[originalMessageId] = processId
      DEPLOYER_TO_LATEST_PROCESS_MAPPING[deployer] = processId
    end
)

Handlers.add(
  "InitAMM",
  Handlers.utils.hasMatchingTag("Action", "Init-AMM"),
  function (msg)
    ao.send({
        Target = ao.id,
        Action = "Eval",
        Data = AMM_PROCESS_CODE,
        Assignments = PROCESSES_PENDING_INIT
    })
    for i, process in ipairs(PROCESSES_PENDING_INIT) do
        table.insert(PROCESSES_INITIALIZED, process)
    end
    PROCESSES_PENDING_INIT = {}
  end
)


Handlers.add(
  "AMMsPending",
  Handlers.utils.hasMatchingTag("Action", "Get-Pending-AMM-Count"),
  function (msg)
    ao.send({
        Target = msg.From,
        ['Pending-AMM-Count'] = tostring(#PROCESSES_PENDING_INIT),
    })
  end
)


Handlers.add(
  "GetProcessId",
  Handlers.utils.hasMatchingTag("Action", "Get-Process-Id"),
  function (msg)
    ao.send({
        Target = msg.From,
        Action = "Process-Id-Response",
        ['Process-Id'] = MESSAGE_TO_PROCESS_MAPPING[msg.Tags['Original-Message-Id']],
    })
  end
)


Handlers.add(
  "GetLatestProcessIdForDeployer",
  Handlers.utils.hasMatchingTag("Action", "Get-Latest-Process-Id-For-Deployer"),
  function (msg)
    ao.send({
        Target = msg.From,
        Action = "Process-Id-Response",
        ['Process-Id'] = DEPLOYER_TO_LATEST_PROCESS_MAPPING[msg.Tags['Deployer']],
    })
  end
)
