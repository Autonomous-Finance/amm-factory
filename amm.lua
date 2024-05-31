AMM_PROCESS_CODE = [===[
    package.preload['.token.credit_notice'] = (function (...)
        local assertions = require ".utils.assertions"
        local pool = require ".pool.pool"
        local utils = require ".utils"
        
        local mod = {}
        
        -- Handle incoming transfers
        ---@param message Message
        function mod.creditNotice(message)
          -- quantity in string format
          local rawQuantity = message.Tags.Quantity
        
          -- validate quantity
          assert(
            assertions.isTokenQuantity(rawQuantity),
            "Invalid token quantity"
          )
        
          -- received token process ID
          local token = message.From
        
          -- forwarded action
          local XAction = message.Tags["X-Action"] or "No-Action"
        
          -- token pair
          local pair = pool.getPair()
        
          -- supported forwarded actions
          local actions = { "Swap", "Provide" }
        
          -- ensure that the token sent is in the pair
          -- and the sender provided a forwarded action
          if utils.includes(token, pair) and utils.includes(XAction, actions) then
            return
          end
        
          -- transfer sender in receipt
          local sender = message.Tags.Sender
        
          -- the token is not in the pair, or the forwarded
          -- action is invalid, refund the tokens
          ao.send({
            Target = token,
            Action = "Transfer",
            Recipient = sender,
            Quantity = rawQuantity,
            ["X-Action"] = utils.includes(XAction, actions) and (XAction .. "-Error") or "Credit-Notice-Error",
            ["X-Error"] = utils.includes(XAction, actions) and "Token is not in pair" or "Invalid forwarded action"
          })
        end
        
        return mod
         end)
        package.preload['.utils.patterns'] = (function (...)
        local mod = {}
        
        -- This function allows the wrapped pattern function
        -- to continue the execution after the handler
        ---@param fn fun(msg: Message)
        ---@return PatternFunction
        function mod.continue(fn)
          return function (msg)
            local patternResult = fn(msg)
        
            if not patternResult or patternResult == 0 or patternResult == "skip" then
              return patternResult
            end
            return 1
          end
        end
        
        -- The "hasMatchingTag" utility function, but it supports
        -- multiple values for the tag
        ---@param name string Tag name
        ---@param values string[] Tag values
        ---@return PatternFunction
        function mod.hasMatchingTagOf(name, values)
          return function (msg)
            for _, value in ipairs(values) do
              local patternResult = Handlers.utils.hasMatchingTag(name, value)(msg)
        
              if patternResult ~= 0 and patternResult ~= false and patternResult ~= "skip" then
                return patternResult
              end
            end
        
            return 0
          end
        end
        
        -- Adds support to chain multiple patterns together
        -- to use in one handler
        ---@param ... PatternFunction Patterns
        ---@return PatternFunction
        function mod._and(...)
          local patterns = {...}
        
          return function (msg)
            for _, pattern in ipairs(patterns) do
              local patternResult = pattern(msg)
        
              if not patternResult or patternResult == 0 or patternResult == "skip" then
                return patternResult
              end
            end
        
            return -1
          end
        end
        
        -- Handlers wrapped with this function will not throw Lua errors.
        -- Instead, if the handler throws an error, the wrapper will
        -- catch that and set the global RefundError to the error message.
        -- We use this to refund the user if anything goes wrong with an
        -- interaction that involves incoming transfers (such as swap or
        -- provide)
        ---@param handler HandlerFunction
        ---@return HandlerFunction
        function mod.catchWrapper(handler)
          -- return the wrapped handler
          return function (msg, env)
            -- execute the provided handler
            local status, result = pcall(handler, msg, env)
        
            -- validate the execution result
            if not status then
              local err = string.gsub(result, "%[[%w_.\" ]*%]:%d*: ", "")
        
              -- set the global RefundError variable
              -- this needs to be reset in the refund later
              RefundError = err
        
              return nil
            end
        
            return result
          end
        end
        
        return mod
         end)
        package.preload['.token.transfer'] = (function (...)
        local assertions = require ".utils.assertions"
        local outputs = require ".utils.output"
        local bint = require ".bint"(512)
        
        local mod = {}
        
        -- Transfer tokens to another user
        ---@param message Message
        function mod.transfer(message)
          -- transfer target
          local target = message.Tags.Recipient or message.Target
        
          -- validate target address
          assertions.Address:assert(target)
        
          -- check if the target and the sender are the same
          assert(target ~= message.From, "Target cannot be the sender")
        
          -- validate quantity
          assert(
            assertions.isTokenQuantity(message.Tags.Quantity),
            "Invalid transfer quantity"
          )
        
          -- transfer quantity
          local quantity = bint(message.Tags.Quantity)
        
          -- validate if the user has enough tokens
          assert(Balances[message.From] ~= nil, "No balance for this user")
          assert(bint.ule(quantity, Balances[message.From]), "Not enought tokens for this transfer")
        
          -- move qty
          Balances[target] = (Balances[target] or bint.zero()) + quantity
          Balances[message.From] = Balances[message.From] - quantity
        
          if not message.Tags.Cast then
            -- credit and debit notices
            local debitNotice = {
              Target = message.From,
              Action = "Debit-Notice",
              Recipient = target,
              Quantity = tostring(quantity)
            }
            local creditNotice = {
              Target = target,
              Action = "Credit-Notice",
              Sender = message.From,
              Quantity = tostring(quantity)
            }
        
            -- add forwarded tags to the credit and debit notice messages
            for tagName, tagValue in pairs(message.Tags) do
              -- tags beginning with "X-" are forwarded
              if string.sub(tagName, 1, 2) == "X-" then
                debitNotice[tagName] = tagValue
                creditNotice[tagName] = tagValue
              end
            end
        
            -- send credit and debit notices
            ao.send(debitNotice)
            ao.send(creditNotice)
          end
        
          print(
            outputs.prefix("Transfer", message.From) ..
            Colors.blue ..
            tostring(quantity) ..
            Colors.gray ..
            " " ..
            Ticker ..
            " to " ..
            outputs.formatAddress(target) ..
            Colors.reset
          )
        end
        
        return mod
         end)
        package.preload['.token.balance'] = (function (...)
        local assertions = require ".utils.assertions"
        local outputs = require ".utils.output"
        local bint = require ".bint"(512)
        local utils = require ".utils"
        local json = require "json"
        
        local balance = {}
        
        -- Balance of a specific user
        ---@param msg Message
        function balance.balance(msg)
          -- find target
          local target = msg.Tags.Target or msg.From
        
          -- check address
          assertions.Address:assert(target)
        
          local bal = Balances[target] or bint.zero()
        
          ao.send({
            Target = msg.From,
            Balance = tostring(bal),
            Ticker = Ticker,
            Data = tostring(bal)
          })
          print(
            outputs.prefix("Balance", msg.From) ..
            Colors.gray ..
            "Balance = " ..
            Colors.blue ..
            tostring(bal) ..
            Colors.reset
          )
        end
        
        -- All holders and their balances
        ---@param msg Message
        function balance.balances(msg)
          -- Convert balances object into raw bigint balances
          ---@type table<string, string>
          local rawBalances = {}
        
          for addr, bal in pairs(Balances) do
            rawBalances[addr] = tostring(bal)
          end
        
          ao.send({
            Target = msg.From,
            Ticker = Ticker,
            Data = json.encode(rawBalances)
          })
          print(
            outputs.prefix("Balances", msg.From) ..
            Colors.gray ..
            "See response data" ..
            Colors.reset
          )
        end
        
        -- Calculate total supply
        ---@return Bint
        function balance.totalSupply()
          return utils.reduce(
            ---@param acc Bint
            ---@param val Bint
            function (acc, val) return bint(acc) + bint(val) end,
            bint.zero(),
            utils.values(Balances)
          ) or bint.zero()
        end
        
        -- Calculate the integer amount of tokens using the token decimals
        -- (balances are stored with the *10^decimals* multiplier)
        ---@param val Bint Main unit qty of tokens
        ---@return Bint
        function balance.toSubUnits(val)
          return val * bint.ipow(bint(10), bint(Denomination))
        end
        
        return balance
         end)
        package.preload['.utils.output'] = (function (...)
        local mod = {}
        
        -- Format an Arweave address
        ---@param addr string Arweave address
        ---@param len number? Lenght of string before "..."
        function mod.formatAddress(addr, len)
          if not len then len = 3 end
          if not addr then return "unknown" end
          return Colors.green ..
            string.sub(addr, 1, len) ..
            "..." ..
            string.sub(addr, -len) ..
            Colors.reset
        end
        
        -- Prefix for an output
        ---@param action string Message action
        ---@param from string Message sender
        function mod.prefix(action, from)
          return Colors.gray ..
            "New " ..
            Colors.blue ..
            action ..
            Colors.gray ..
            " from " ..
            mod.formatAddress(from) ..
            Colors.gray ..
            ": " ..
            Colors.reset
        end
        
        return mod
         end)
        package.preload['.pool.provide'] = (function (...)
        local assertions = require ".utils.assertions"
        local bintmath = require ".utils.bintmath"
        local balance = require ".token.balance"
        local outputs = require ".utils.output"
        local bint = require ".bint"(512)
        local pool = require ".pool.pool"
        local utils = require ".utils"
        
        local mod = {}
        
        ---@alias PendingProvide { id: string; token: string; quantity: Bint; sender: string; }
        
        -- Provide interaction
        ---@param message Message
        function mod.provide(message)
          -- incoming token ID
          local tokenB = message.From
        
          -- sender address
          local sender = message.Tags.Sender
        
          -- find pending provide (other token's transfer)
          ---@type PendingProvide|nil
          local pendingProvide = utils.find(
            ---@param val PendingProvide
            function (val) return val.sender == sender end,
            PendingProvides
          )
        
          -- pending provide was found, but with the same token
          -- or pending provide was not found
          if not pendingProvide or pendingProvide.token == tokenB then
            -- pending provide to add, with the quantity
            -- to add + the quantity that is pending
            -- (0 if no pending provides were found)
            ---@type PendingProvide
            local newPendingProvide = {
              id = pendingProvide and pendingProvide.id or message.Id,
              token = tokenB,
              quantity = (pendingProvide and pendingProvide.quantity or bint.zero()) + bint(message.Tags.Quantity),
              sender = sender
            }
        
            -- filter out the existing pending provide
            if pendingProvide then
              mod.closePending({ id = pendingProvide.id })
            end
        
            -- insert new pending provide
            table.insert(PendingProvides, newPendingProvide)
        
            -- indicate pending provide action
            ao.send({
              Target = sender,
              Action = "Provide-Pending",
              ["Provide-Id"] = message.Id,
              ["Provide-Quantity"] = tostring(newPendingProvide.quantity),
              ["Waiting-For"] = utils.find(function (v) return v ~= tokenB end, pool.getPair()) or ""
            })
        
            -- print result
            print(
              outputs.prefix("Provide", sender) ..
              Colors.blue ..
              message.Tags.Quantity ..
              " " ..
              outputs.formatAddress(tokenB) ..
              Colors.gray ..
              " pending..." ..
              Colors.reset
            )
        
            -- return (the process waits for a transfer of the other token of the pair)
            return
          end
        
          -- these quantities need to be adjusted if the ratio is not correct
          local qtyA = pendingProvide.quantity
          ---@type Bint
          local qtyB = bint(message.Tags.Quantity)
        
          -- the ID of the token in the pending provide interaction
          local tokenA = pendingProvide.token
        
          -- slippage tolerance in %
          local slippageTolerance = tonumber(message.Tags["X-Slippage-Tolerance"])
        
          -- verify slippage percentage
          assert(
            assertions.isSlippagePercentage(slippageTolerance),
            "Invalid slippage tolerance percentage"
          )
          ---@cast slippageTolerance number
        
          -- whether or not the pool is empty (if it is, then this is the first provide interaction)
          local initialProvide = bint.eq(Reserves[tokenA], bint.zero()) and bint.eq(Reserves[tokenB], bint.zero())
        
          -- whether or not the ratio matches
          local ratioMatches = bint.eq(
            qtyA * Reserves[tokenB],
            qtyB * Reserves[tokenA]
          )
        
          -- check the ratio and adjust the input quantities if needed
          if not initialProvide and not ratioMatches then
            -- slippage limits for B tokens
            local limitB = pool.slippageLimit(slippageTolerance, qtyB, "lower")
            local optimalB = bint.udiv(Reserves[tokenB] * qtyA, Reserves[tokenA])
        
            -- check if it is possible to execute the provide interaction
            -- by adjusting qtyB and if it is within the slippage tolerance
            -- if it is not, we try the same thing by adjusting qtyB
            if bint.ule(optimalB, qtyB) and bint.ule(limitB, optimalB) then
              -- update qtyB to optimal value
              qtyB = optimalB
            else
              -- slippage limits for A
              local limitA = pool.slippageLimit(slippageTolerance, qtyA, "lower")
              local optimalA = bint.udiv(Reserves[tokenA] * qtyB, Reserves[tokenB])
        
              -- make sure it is possible to execute the provide interaction
              -- with the provided slippage limit by adjusting qtyA
              -- if it is not possible, the provide interaction cannot be
              -- executed and the tokens will be refunded within the refund
              -- finalizer
              assert(
                bint.ule(optimalA, qtyA) and bint.ule(limitA, optimalA),
                "Could not provide liquidity within the given slippage tolerance"
              )
        
              -- update qtyA to optimal value
              qtyA = optimalA
            end
          end
        
          -- the amount of pool tokens to be minted for the LP
          local ptToMint = bint.zero()
        
          -- if this is the initial provide interaction,
          -- we mint the user the sqrt of the two qtys
          -- multiplied
          if initialProvide then
            ptToMint = bintmath.sqrt(qtyA * qtyB)
          else
            -- if this was not the initial provide interaction, we need to
            -- calculate the amount of pool tokens the user receives
            -- the LP receives pool tokens in the ratio of the incoming tokens
            -- and the tokens in the reserves
            -- this NEEDS to be calculated before adding the incoming tokens
            -- to the reserves
            ptToMint = bint.udiv(
              balance.totalSupply() * qtyA,
              Reserves[tokenA]
            )
          end
        
          -- check if the received pool tokens are > 0
          assert(bint.ult(bint.zero(), ptToMint), "Too little liquidity provided")
        
          -- mint tokens
          Balances[sender] = (Balances[sender] or bint.zero()) + ptToMint
        
          -- add to reserves
          Reserves[tokenA] = Reserves[tokenA] + qtyA
          Reserves[tokenB] = Reserves[tokenB] + qtyB
        
          -- see if we need to transfer back any tokens, this is needed if
          -- the rate was adjusted compared to the incoming token qtys
          --
          -- check for tokenA
          if bint.ult(qtyA, pendingProvide.quantity) then
            ao.send({
              Target = tokenA,
              Action = "Transfer",
              Recipient = sender,
              Quantity = tostring(pendingProvide.quantity - qtyA)
            })
          end
        
          -- check for tokenB
          if bint.ult(qtyB, bint(message.Tags.Quantity)) then
            ao.send({
              Target = tokenB,
              Action = "Transfer",
              Recipient = sender,
              Quantity = tostring(bint(message.Tags.Quantity) - qtyB)
            })
          end
        
          -- remove pending provide(s)
          mod.closePending({ sender = sender })
        
          -- return result
          ao.send({
            Target = sender,
            Action = "Provide-Confirmation",
            ["Provide-Id"] = message.Id,
            ["Received-Pool-Tokens"] = tostring(ptToMint),
            ["Provided-" .. tokenA] = tostring(qtyA),
            ["Provided-" .. tokenB] = tostring(qtyB)
          })
        
          -- print result
          print(
            outputs.prefix("Provide", sender) ..
            Colors.blue ..
            tostring(qtyA) ..
            " " ..
            outputs.formatAddress(tokenA) ..
            Colors.gray ..
            " + " ..
            Colors.blue ..
            tostring(qtyB) ..
            " " ..
            outputs.formatAddress(tokenB) ..
            Colors.gray ..
            " → " ..
            Colors.blue ..
            tostring(ptToMint) ..
            " " ..
            Colors.green ..
            "POOL TOKENS" ..
            Colors.reset
          )
        end
        
        -- Close and remove a pending provide for a user
        ---@param data { sender?: string, id?: string }
        function mod.closePending(data)
          if not data.sender and not data.id then return end
        
          PendingProvides = utils.filter(
            ---@param val PendingProvide
            function (val)
              if data.id then
                return val.id ~= data.id
              end
        
              return val.sender ~= data.sender
            end,
            PendingProvides
          ) or {}
        end
        
        return mod
         end)
        package.preload['.pool.refund'] = (function (...)
        local outputs = require ".utils.output"
        local provide = require ".pool.provide"
        local utils = require ".utils"
        
        local mod = {}
        
        -- these are the supported actions that can invoke
        -- the refund mechanism
        ---@alias SupportedRefundActions "Swap"|"Provide"
        
        -- This function refunds the user if the swap/provide interaction failed
        function mod.refund(message)
          -- if the refund error is undefined, we don't need
          -- to refund the user
          if not RefundError then return end
        
          -- message action
          ---@type SupportedRefundActions
          local action = message.Tags["X-Action"]
        
          ---@type table<SupportedRefundActions, string>
          local sourceInteractionIDs = {
            Swap = "Order",
            Provide = "Provide"
          }
        
          -- sender of the transfer
          local sender = message.Tags.Sender
        
          -- refund this transfer (that the credit-notice indicated)
          ao.send({
            Target = message.From,
            Action = "Transfer",
            Recipient = sender,
            Quantity = message.Tags.Quantity,
            ["X-Refunded-Transfer"] = message.Tags["Pushed-For"],
            ["X-Refunded-" .. sourceInteractionIDs[action]] = message.Id
          })
        
          -- if this is a provide interaction, we also need to
          -- refund the provide 
          if action == "Provide" then
            -- find pending provide
            local pendingProvide = utils.find(
              ---@param val PendingProvide
              function (val) return val.sender == sender end,
              PendingProvides
            )
        
            -- pending provide for this user was found,
            -- refund and remove it from the list of
            -- pending provides
            if pendingProvide then
              -- refund
              ao.send({
                Target = pendingProvide.token,
                Action = "Transfer",
                Recipient = sender,
                Quantity = tostring(pendingProvide.quantity),
                ["X-Refunded-Transfer"] = pendingProvide.id,
                ["X-Refunded-" .. sourceInteractionIDs[action]] = message.Id
              })
        
              -- remove
              provide.closePending({ id = pendingProvide.id })
            end
          end
        
          -- error actions for each handler
          ---@type table<SupportedRefundActions, string>
          local errorActions = {
            Swap = "Order-Error",
            Provide = "Provide-Error"
          }
        
          -- send error message to the sender of the swap/provide message
          -- the error message is the global RefundError variable set by 
          -- one of the failed assertions in swap/provide
          ao.send({
            Target = sender,
            Action = errorActions[action],
            [sourceInteractionIDs[action] .. "-Id"] = message.Id,
            Result = RefundError
          })
        
          -- print refund result
          print(
            outputs.prefix("Refund", sender) ..
            Colors.gray ..
            "Refunding " ..
            Colors.blue ..
            action ..
            " " ..
            Colors.gray ..
            "(" ..
            RefundError ..
            ")" ..
            Colors.reset
          )
        
          -- reset refund error
          -- this is IMPORTANT, so the handler won't interpret
          -- future messages/interactions as failed
          RefundError = nil
        end
        
        return mod
         end)
        package.preload['.pool.cancel'] = (function (...)
        local assertions = require ".utils.assertions"
        local outputs = require ".utils.output"
        local provide = require ".pool.provide"
        local utils = require ".utils"
        
        local mod = {}
        
        -- Refunds a transfer if it has not been used yet
        ---@type HandlerFunction
        function mod.cancel(message)
          -- the incoming token transfer ID
          local transferID = message.Tags.Transfer
        
          assertions.Address:assert(transferID)
        
          -- find the transfer and validate it
          ---@type PendingProvide|nil
          local transfer = utils.find(
            ---@param val PendingProvide
            function (val) return val.id == transferID end,
            PendingProvides
          )
        
          assert(transfer ~= nil, "Could not find provided transfer")
          assert(transfer.sender == message.From, "Transfer owner is not the caller")
        
          -- send back the tokens
          ao.send({
            Target = transfer.token,
            Action = "Transfer",
            Recipient = transfer.sender,
            Quantity = tostring(transfer.quantity)
          })
        
          -- remove the pending provide (transfer)
          provide.closePending({ id = transfer.id })
        
          -- send a notice about the refund
          ao.send({
            Target = transfer.sender,
            Action = "Refund-Notice",
            Transfer = transfer.id,
            Quantity = tostring(transfer.quantity)
          })
        
          -- print result
          print(
            outputs.prefix("Cancel", message.From) ..
            Colors.gray ..
            "Sending back " ..
            Colors.blue ..
            tostring(transfer.quantity) ..
            " " ..
            outputs.formatAddress(transfer.token) ..
            Colors.gray ..
            " to " ..
            outputs.formatAddress(transfer.sender)
          )
        end
        
        return mod
         end)
        package.preload['.token.token'] = (function (...)
        local outputs = require ".utils.output"
        local bint = require ".bint"(512)
        local json = require "json"
        
        local mod = {}
        
        -- Init token globals
        function mod.init()
          ---@type Balances
          Balances = Balances or {
            [ao.id] = bint.zero()
          }
        
          Name = Name or ao.env.Process.Tags["Name"]
          Ticker = Ticker or "POOL"
          Denomination = Denomination or 12
          Logo = Logo or "logo here"
        
          print(
            Colors.gray ..
            "Token was set up: " ..
            outputs.formatAddress(ao.id)
          )
        end
        
        -- Get info about the token
        ---@param msg Message
        function mod.info(msg)
          -- summarize token info in a table
          local tokenInfo = {
            Name = Name,
            Ticker = Ticker,
            Logo = Logo,
            Denomination = tostring(Denomination)
          }
        
          print(
            outputs.prefix("Info", msg.From) ..
            Colors.gray ..
            "Name = " ..
            Colors.blue ..
            Name ..
            Colors.gray ..
            ", Ticker = " ..
            Colors.blue ..
            Ticker ..
            Colors.gray ..
            ", Logo = " ..
            outputs.formatAddress(Logo) ..
            Colors.gray ..
            ", Denomination = " ..
            Colors.blue ..
            Denomination ..
            Colors.reset
          )
        
          tokenInfo["Target"] = msg.From
          ao.send(tokenInfo)
        end
        
        return mod
         end)
        package.preload['.pool.burn'] = (function (...)
        local assertions = require ".utils.assertions"
        local balances = require ".token.balance"
        local outputs = require ".utils.output"
        local bint = require ".bint"(512)
        local pool = require ".pool.pool"
        
        local mod = {}
        
        -- Burn interaction
        ---@param message Message
        function mod.burn(message)
          -- validate quantity
          assert(
            assertions.isTokenQuantity(message.Tags.Quantity),
            "Invalid burn quantity"
          )
        
          -- burn quantity
          local quantity = bint(message.Tags.Quantity)
        
          -- validate if the user has enough tokens
          assert(Balances[message.From] ~= nil, "No balance for this user")
          assert(bint.ule(quantity, Balances[message.From]), "Not enought tokens to burn")
        
          -- make sure the LP does not burn the total supply,
          -- as this action would drain the pool
          local totalSupply = balances.totalSupply()
        
          assert(bint.ult(quantity, totalSupply), "This action would drain the pool")
        
          -- calculate the amount of tokenA and tokenB the LP
          -- is going to be withdrawing for the burned tokens
        
          -- calculate the ratio of tokens going out of
          -- the pool using the ratio of the burned tokens
          -- to the total supply of pool tokens
          ---@param inReserve Bint Amount in the reserve
          ---@return Bint
          local function burnRatioOf(inReserve)
            return bint.udiv(quantity * inReserve, totalSupply)
          end
        
          -- the pool's pair
          local pair = pool.getPair()
        
          -- tokenA transfer
          local tokenA = pair[1]
          local tokenAQty = burnRatioOf(Reserves[tokenA])
        
          ao.send({
            Target = tokenA,
            Action = "Transfer",
            Recipient = message.From,
            Quantity = tostring(tokenAQty)
          })
        
          -- remove tokenA from the reserves
          Reserves[tokenA] = Reserves[tokenA] - tokenAQty
        
          -- tokenB transfer
          local tokenB = pair[2]
          local tokenBQty = burnRatioOf(Reserves[tokenB])
        
          ao.send({
            Target = tokenB,
            Action = "Transfer",
            Recipient = message.From,
            Quantity = tostring(tokenBQty)
          })
        
          -- remove tokenB from the reserves
          Reserves[tokenB] = Reserves[tokenB] - tokenBQty
        
          -- finally, burn the tokens
          Balances[message.From] = Balances[message.From] - quantity
        
          -- reply
          ao.send({
            Target = message.From,
            ["Burned-Pool-Tokens"] = tostring(quantity),
            ["Withdrawn-" .. tokenA] = tostring(tokenAQty),
            ["Withdrawn-" .. tokenB] = tostring(tokenBQty)
          })
        
          -- print result
          print(
            outputs.prefix("Burn", message.From) ..
            Colors.blue ..
            tostring(quantity) ..
            " " ..
            Colors.green ..
            "POOL TOKENS" ..
            Colors.gray ..
            " → " ..
            Colors.blue ..
            tostring(tokenAQty) ..
            " " ..
            outputs.formatAddress(tokenA) ..
            Colors.gray ..
            " + " ..
            Colors.blue ..
            tostring(tokenBQty) ..
            " " ..
            outputs.formatAddress(tokenB)
          )
        end
        
        return mod
         end)
        package.preload['.pool.pool'] = (function (...)
        local assertions = require ".utils.assertions"
        local outputs = require ".utils.output"
        local bint = require ".bint"(512)
        local utils = require ".utils"
        local bintmath = require ".utils.bintmath"
        
        local pool = {}
        
        -- Get pool token pair
        ---@return string[]
        function pool.getPair()
          -- token A
          local tokenA = ao.env.Process.Tags["Token-A"]
        
          -- token B
          local tokenB = ao.env.Process.Tags["Token-B"]
        
          return { tokenA, tokenB }
        end
        
        -- Get reserves
        function pool.getReserves() return Reserves end
        
        -- Get constant K of the AMM formula
        ---@return Bint
        function pool.K()
          local pair = pool.getPair()
        
          return Reserves[pair[1]] * Reserves[pair[2]]
        end
        
        -- Fee distributed between the LPs
        -- TODO: this could be parsed from the environment/
        -- init message tags. When doing that, it should be
        -- checked if the fee percentage is 0.0001<= fee < 100
        function pool.getLPFeePercentage() return 0 end
        
        -- Raw token output qty function
        ---@param input Bint Input qty (in base amount)
        ---@param token string Token address
        ---@return Bint
        function pool.getOutput(input, token)
          -- the token pair of this pool
          local pair = pool.getPair()
        
          -- constant K
          local K = pool.K()
        
          -- find the other token in the pair
          local otherToken = utils.find(
            function (val) return val ~= token end,
            pair
          )
        
          -- x * y = k
          -- (x + in) * (y - out) = k
          -- y - out = k / (x + in)
          -- -out = k / (x + in) - y
          -- out = y - k / (x + in)
          local out = Reserves[otherToken] - bintmath.div_round_up(K, (Reserves[token] + input))
        
          return out
        end
        
        -- Get the price of one token in the units of the other
        ---@param msg Message
        function pool.getPrice(msg)
          -- token to get the price for
          local token = msg.Tags.Token
        
          -- the token pair of this pool
          local pair = pool.getPair()
        
          if not utils.includes(token, pair) then
            ao.send({
              Target = msg.From,
              Price = "0"
            })
            print(
              outputs.prefix("Get-Price", msg.From) ..
              Colors.gray ..
              "Price = " ..
              Colors.blue ..
              "0" ..
              Colors.reset
            )
            return
          end
        
          -- verify optional quantity
          assert(
            msg.Tags.Quantity == nil or assertions.isTokenQuantity(msg.Tags.Quantity),
            "Invalid quantity"
          )
        
          -- optional quantity
          local quantity = msg.Tags.Quantity and bint(msg.Tags.Quantity) or bint.one()
        
          -- final price
          local price = pool.getOutput(quantity, token)
        
          ao.send({
            Target = msg.From,
            Price = tostring(price)
          })
          print(
            outputs.prefix("Get-Price", msg.From) ..
            Colors.gray ..
            "Price = " ..
            Colors.blue ..
            tostring(price) ..
            Colors.reset
          )
        end
        
        -- Initialize the pool
        function pool.init()
          local pair = pool.getPair()
        
          ---@type table<string, Bint>
          Reserves = Reserves or {
            [pair[1]] = bint.zero(),
            [pair[2]] = bint.zero()
          }
        
          ---@type PendingProvide[]
          PendingProvides = PendingProvides or {}
        
          print(
            Colors.gray ..
            "Pool was set up for pair: " ..
            outputs.formatAddress(pair[1]) ..
            Colors.gray ..
            "/" ..
            outputs.formatAddress(pair[2])
          )
        end
        
        -- Calculate the slippage limit for a provided tolerance and
        -- expected output
        ---@param tolerance number Slippage tolerance percentage
        ---@param expected Bint Expected output
        ---@param limit "lower"|"upper" Limit type (always required for readability)
        ---@return Bint
        function pool.slippageLimit(tolerance, expected, limit)
          -- account for lower limit
          if limit == "lower" then tolerance = -tolerance end
        
          -- account for precision
          local multiplier = 100
          local multipliedPercentage = (100 + tolerance) * multiplier
        
          -- calculate limit
          return bint.udiv(
            expected * bint(multipliedPercentage),
            bint(100 * multiplier)
          )
        end
        
        return pool
         end)
        package.preload['.pool.swap'] = (function (...)
        local assertions = require ".utils.assertions"
        local outputs = require ".utils.output"
        local bint = require ".bint"(512)
        local pool = require ".pool.pool"
        
        local mod = {}
        
        -- Swap interaction
        ---@param message Message
        function mod.swap(message)
          -- get pair
          local pair = pool.getPair()
        
          -- check if the reserves are empty
          assert(
            bint.ult(bint.zero(), Reserves[pair[1]]) and bint.ult(bint.zero(), Reserves[pair[2]]),
            "The reserves are empty"
          )
        
          -- verify expected output
          assert(
            assertions.isTokenQuantity(message.Tags["X-Expected-Output"]),
            "Invalid expected output quantity"
          )
        
          -- expected output for slippage
          local expectedOutput = bint(message.Tags["X-Expected-Output"])
        
          -- slippage tolerance in %
          local slippageTolerance = tonumber(message.Tags["X-Slippage-Tolerance"])
        
          -- verify slippage percentage
          assert(
            assertions.isSlippagePercentage(slippageTolerance),
            "Invalid slippage tolerance percentage"
          )
          ---@cast slippageTolerance number
        
          -- quantity was already verified in the credit notice handler
          local inputQty = bint(message.Tags.Quantity)
        
          -- LP fee
          local fee = pool.getLPFeePercentage()
        
          -- fee adjusted incoming token qty (2 fractions of precision)
          local precisionMultiplier = 100
          local incomingQtyFeeAdjusted = bint.udiv(
            inputQty * bint(math.floor((100 - fee) * precisionMultiplier)),
            bint(100 * precisionMultiplier)
          )
        
          -- the quantity of tokens sent to the LPs as fees
          local feeQty = inputQty - incomingQtyFeeAdjusted
        
          -- the ID of the token sent
          local inputToken = message.From
        
          -- the ID of the token the AMM is going to send to the caller
          local outputToken = inputToken == pair[1] and pair[2] or pair[1]
        
          -- calculate output
          local outputQty = pool.getOutput(
            incomingQtyFeeAdjusted,
            inputToken
          )
        
          -- the reserves after the swap
          local newReserves = {
            [pair[1]] = Reserves[pair[1]],
            [pair[2]] = Reserves[pair[2]]
          }
        
          -- calculate new quantities (including the deposited fee)
          newReserves[inputToken] = newReserves[inputToken] + inputQty
          newReserves[outputToken] = newReserves[outputToken] - outputQty
        
          -- validate if the reserves hold enough tokens for the swap to execute (this should be impossible)
          assert(bint.ult(bint.zero(), newReserves[outputToken]), "This swap would drain the pool")
        
          -- validate the output qty, if it is 0 or less, then the pool does not have enought liquidity
          assert(
            bint.ult(bint.zero(), outputQty),
            "There isn't enough liquidity in the reserves to complete this order"
          )
        
          -- calculate slippage limits
          local slippageMin = pool.slippageLimit(
            slippageTolerance,
            expectedOutput,
            "lower"
          )
          local slippageMax = pool.slippageLimit(
            slippageTolerance,
            expectedOutput,
            "upper"
          )
        
          -- compare output qty to the slippage limits
          -- if the output is outside the limits, send back the tokens
          assert(
            bint.ule(outputQty, slippageMax) and bint.ule(slippageMin, outputQty),
            "Could not match at provided slippage"
          )
        
          -- add to reserves
          Reserves[pair[1]] = newReserves[pair[1]]
          Reserves[pair[2]] = newReserves[pair[2]]
        
          -- order owner
          local sender = message.Tags.Sender
        
          -- send out tokens
          ao.send({
            Target = outputToken,
            Action = "Transfer",
            Recipient = sender,
            Quantity = tostring(outputQty)
          })
        
          -- return result
          ao.send({
            Target = sender,
            Action = "Order-Confirmation",
            ["Order-Id"] = message.Id,
            ["From-Token"] = inputToken,
            ["From-Quantity"] = tostring(inputQty),
            ["To-Token"] = outputToken,
            ["To-Quantity"] = tostring(outputQty),
            Fee = tostring(feeQty)
          })
        
          -- print result
          print(
            outputs.prefix("Swap", sender) ..
            Colors.blue ..
            tostring(inputQty) ..
            " " ..
            outputs.formatAddress(inputToken) ..
            Colors.gray ..
            " → " ..
            Colors.blue ..
            tostring(outputQty) ..
            " " ..
            outputs.formatAddress(outputToken) ..
            Colors.reset
          )
        end
        
        return mod
         end)
        package.preload['.utils.assertions'] = (function (...)
        local Type = require ".utils.type"
        local bint = require ".bint"(512)
        
        local mod = {}
        
        -- Validates if the provided value can be parsed as a Bint
        ---@param val any Value to validate
        ---@return boolean
        function mod.isBintRaw(val)
          local success, result = pcall(
            function ()
              -- check if the value is convertible to a Bint
              if type(val) ~= "number" and type(val) ~= "string" and not bint.isbint(val) then
                return false
              end
        
              -- check if the val is an integer and not infinity, in case if the type is number
              if type(val) == "number" and (val ~= val or val % 1 ~= 0) then
                return false
              end
        
              return true
            end
          )
        
          return success and result
        end
        
        -- Verify if the provided value can be converted to a valid token quantity
        ---@param qty any Raw quantity to verify
        ---@return boolean
        function mod.isTokenQuantity(qty)
          if type(qty) == "nil" then return false end
          if not mod.isBintRaw(qty) then return false end
          if type(qty) == "number" and qty < 0 then return false end
          if type(qty) == "string" and string.sub(qty, 1, 1) == "-" then
            return false
          end
        
          return true
        end
        
        mod.Address = Type
          :string("Invalid type for Arweave address (must be string)")
          :length(43, nil, "Invalid length for Arweave address")
          :match("[A-z0-9_-]+", "Invalid characters in Arweave address")
        
        -- Verify if the provided value is an address
        ---@param addr any Address to verify
        ---@return boolean
        function mod.isAddress(addr)
          return mod.Address:assert(addr, nil, true)
        end
        
        -- Verify if the provided value is a valid percentage for slippages
        -- Allowed precision is 2 decimals (min is 0.01)
        ---@param percentage any Percentage to verify
        ---@return boolean
        function mod.isSlippagePercentage(percentage)
          return type(percentage) == "number" and
            percentage > 0 and
            (percentage * 100) % 1 == 0 and
            percentage < 100
        end
        
        return mod
         end)
        package.preload['.utils.bintmath'] = (function (...)
        local bint = require ".bint"(512)
        
        local mod = {}
        
        -- Returns the square root of the provided bigint
        -- using the babylonian/Heron's method (rounds down)
        ---@param x Bint Unsigned integer to get the sqrt for
        ---@return Bint
        function mod.sqrt(x)
          -- handle trivial cases
          if bint.eq(x, bint.zero()) then return bint.zero() end
          if bint.ule(x, bint(3)) then return bint.one() end
        
          -- apply the algorithm
          local res = x
          local next = bint.udiv(x, bint(2)) + bint.one()
        
          while bint.ult(next, res) do
            res = next
            next = bint.udiv(bint.udiv(x, next) + next, bint(2))
          end
        
          return res
        end
        
        --- Perform division rounding up between two numbers considering bints.
        -- @param x The numerator, a bint or lua number.
        -- @param y The denominator, a bint or lua number.
        -- @return The quotient rounded up, a bint or lua number.
        -- @raise Asserts on attempt to divide by zero.
        function mod.div_round_up(x, y)
          local ix, iy = bint.tobint(x), bint.tobint(y)
          if ix and iy then
            local quot, rem = bint.tdivmod(ix, iy)
            if not rem:iszero() and (bint.ispos(x) == bint.ispos(y)) then
              quot:_inc()
            end
            return quot
          end
          local nx, ny = bint.tonumber(x), bint.tonumber(y)
          local quotient = nx / ny
          if quotient ~= math.floor(quotient) then
            return math.ceil(quotient)
          end
          return quotient
        end
        
        return mod
         end)
        package.preload['.utils.type'] = (function (...)
        ---@class Type
        local Type = {
          -- custom name for the defined type
          ---@type string|nil
          name = nil,
          -- list of assertions to perform on any given value
          ---@type { message: string, validate: fun(val: any): boolean }[]
          conditions = nil
        }
        
        -- Execute an assertion for a given value
        ---@param val any Value to assert for
        ---@param message string? Optional message to throw
        ---@param no_error boolean? Optionally disable error throwing (will return boolean)
        function Type:assert(val, message, no_error)
          for _, condition in ipairs(self.conditions) do
            if not condition.validate(val) then
              if no_error then return false end
              self:error(message or condition.message)
            end
          end
        
          if no_error then return true end
        end
        
        -- Add a custom condition/assertion to assert for
        ---@param message string Error message for the assertion
        ---@param assertion fun(val: any): boolean Custom assertion function that is asserted with the provided value
        function Type:custom(message, assertion)
          -- condition to add
          local condition = {
            message = message,
            validate = assertion
          }
        
          -- new instance if there are no conditions yet
          if self.conditions == nil then
            local instance = {
              conditions = {}
            }
        
            table.insert(instance.conditions, condition)
            setmetatable(instance, self)
            self.__index = self
        
            return instance
          end
        
          table.insert(self.conditions, condition)
          return self
        end
        
        -- Add an assertion for built in types
        ---@param t "nil"|"number"|"string"|"boolean"|"table"|"function"|"thread"|"userdata" Type to assert for
        ---@param message string? Optional assertion error message
        function Type:type(t, message)
          return self:custom(
            message or ("Not of type (" .. t .. ")"),
            function (val) return type(val) == t end
          )
        end
        
        -- Type must be userdata
        ---@param message string? Optional assertion error message
        function Type:userdata(message)
          return self:type("userdata", message)
        end
        
        -- Type must be thread
        ---@param message string? Optional assertion error message
        function Type:thread(message)
          return self:type("thread", message)
        end
        
        -- Type must be table
        ---@param message string? Optional assertion error message
        function Type:table(message)
          return self:type("table", message)
        end
        
        -- Table's keys must be of type t
        ---@param t Type Type to assert the keys for
        ---@param message string? Optional assertion error message
        function Type:keys(t, message)
          return self:custom(
            message or "Invalid table keys",
            function (val)
              if type(val) ~= "table" then
                return false
              end
        
              for key, _ in pairs(val) do
                -- check if the assertion throws any errors
                local success = pcall(function () return t:assert(key) end)
        
                if not success then return false end
              end
        
              return true
            end
          )
        end
        
        -- Type must be array
        ---@param message string? Optional assertion error message
        function Type:array(message)
          return self:table():keys(Type:number(), message)
        end
        
        -- Table's values must be of type t
        ---@param t Type Type to assert the values for
        ---@param message string? Optional assertion error message
        function Type:values(t, message)
          return self:custom(
            message or "Invalid table values",
            function (val)
              if type(val) ~= "table" then return false end
        
              for _, v in pairs(val) do
                -- check if the assertion throws any errors
                local success = pcall(function () return t:assert(v) end)
        
                if not success then return false end
              end
        
              return true
            end
          )
        end
        
        -- Type must be boolean
        ---@param message string? Optional assertion error message
        function Type:boolean(message)
          return self:type("boolean", message)
        end
        
        -- Type must be function
        ---@param message string? Optional assertion error message
        function Type:_function(message)
          return self:type("function", message)
        end
        
        -- Type must be nil
        ---@param message string? Optional assertion error message
        function Type:_nil(message)
          return self:type("nil", message)
        end
        
        -- Value must be the same
        ---@param val any The value the assertion must be made with
        ---@param message string? Optional assertion error message
        function Type:is(val, message)
          return self:custom(
            message or "Value did not match expected value (Type:is(expected))",
            function (v) return v == val end
          )
        end
        
        -- Type must be string
        ---@param message string? Optional assertion error message
        function Type:string(message)
          return self:type("string", message)
        end
        
        -- String type must match pattern
        ---@param pattern string Pattern to match
        ---@param message string? Optional assertion error message
        function Type:match(pattern, message)
          return self:custom(
            message or ("String did not match pattern \"" .. pattern .. "\""),
            function (val) return string.match(val, pattern) ~= nil end
          )
        end
        
        -- String type must be of defined length
        ---@param len number Required length
        ---@param match_type? "less"|"greater" String length should be "less" than or "greater" than the defined length. Leave empty for exact match.
        ---@param message string? Optional assertion error message
        function Type:length(len, match_type, message)
          local match_msgs = {
            less = "String length is not less than " .. len,
            greater = "String length is not greater than " .. len,
            default = "String is not of length " .. len
          }
        
          return self:custom(
            message or (match_msgs[match_type] or match_msgs.default),
            function (val)
              local strlen = string.len(val)
        
              -- validate length
              if match_type == "less" then return strlen < len
              elseif match_type == "greater" then return strlen > len end
        
              return strlen == len
            end
          )
        end
        
        -- Type must be a number
        ---@param message string? Optional assertion error message
        function Type:number(message)
          return self:type("number", message)
        end
        
        -- Number must be an integer (chain after "number()")
        ---@param message string? Optional assertion error message
        function Type:integer(message)
          return self:custom(
            message or "Number is not an integer",
            function (val) return val % 1 == 0 end
          )
        end
        
        -- Number must be even (chain after "number()")
        ---@param message string? Optional assertion error message
        function Type:even(message)
          return self:custom(
            message or "Number is not even",
            function (val) return val % 2 == 0 end
          )
        end
        
        -- Number must be odd (chain after "number()")
        ---@param message string? Optional assertion error message
        function Type:odd(message)
          return self:custom(
            message or "Number is not odd",
            function (val) return val % 2 == 1 end
          )
        end
        
        -- Number must be less than the number "n" (chain after "number()")
        ---@param n number Number to compare with
        ---@param message string? Optional assertion error message
        function Type:less_than(n, message)
          return self:custom(
            message or ("Number is not less than " .. n),
            function (val) return val < n end
          )
        end
        
        -- Number must be greater than the number "n" (chain after "number()")
        ---@param n number Number to compare with
        ---@param message string? Optional assertion error message
        function Type:greater_than(n, message)
          return self:custom(
            message or ("Number is not greater than" .. n),
            function (val) return val > n end
          )
        end
        
        -- Make a type optional (allow them to be nil apart from the required type)
        ---@param t Type Type to assert for if the value is not nil
        ---@param message string? Optional assertion error message
        function Type:optional(t, message)
          return self:custom(
            message or "Optional type did not match",
            function (val)
              if val == nil then return true end
        
              t:assert(val)
              return true
            end
          )
        end
        
        -- Table must be of object
        ---@param obj { [any]: Type }
        ---@param strict? boolean Only allow the defined keys from the object, throw error on other keys (false by default)
        ---@param message string? Optional assertion error message
        function Type:object(obj, strict, message)
          if type(obj) ~= "table" then
            self:error("Invalid object structure provided for object assertion (has to be a table):\n" .. tostring(obj))
          end
        
          return self:custom(
            message or ("Not of defined object (" .. tostring(obj) .. ")"),
            function (val)
              if type(val) ~= "table" then return false end
        
              -- for each value, validate
              for key, assertion in pairs(obj) do
                if val[key] == nil then return false end
        
                -- check if the assertion throws any errors
                local success = pcall(function () return assertion:assert(val[key]) end)
        
                if not success then return false end
              end
        
              -- in strict mode, we do not allow any other keys
              if strict then
                for key, _ in pairs(val) do
                  if obj[key] == nil then return false end
                end
              end
        
              return true
            end
          )
        end
        
        -- Type has to be either one of the defined assertions
        ---@param ... Type Type(s) to assert for
        function Type:either(...)
          ---@type Type[]
          local assertions = {...}
        
          return self:custom(
            "Neither types matched defined in (Type:either(...))",
            function (val)
              for _, assertion in ipairs(assertions) do
                if pcall(function () return assertion:assert(val) end) then
                  return true
                end
              end
        
              return false
            end
          )
        end
        
        -- Type cannot be the defined assertion (tip: for multiple negated assertions, use Type:either(...))
        ---@param t Type Type to NOT assert for
        ---@param message string? Optional assertion error message
        function Type:is_not(t, message)
          return self:custom(
            message or "Value incorrectly matched with the assertion provided (Type:is_not())",
            function (val)
              local success = pcall(function () return t:assert(val) end)
        
              return not success
            end
          )
        end
        
        -- Set the name of the custom type
        -- This will be used with error logs
        ---@param name string Name of the type definition
        function Type:set_name(name)
          self.name = name
          return self
        end
        
        -- Throw an error
        ---@param message any Message to log
        ---@private
        function Type:error(message)
          error("[Type " .. (self.name or tostring(self.__index)) .. "] " .. tostring(message))
        end
        
        return Type
         end)
        local incoming = require ".token.credit_notice"
        local patterns = require ".utils.patterns"
        local transfer = require ".token.transfer"
        local balance = require ".token.balance"
        local outputs = require ".utils.output"
        local provide = require ".pool.provide"
        local refund = require ".pool.refund"
        local cancel = require ".pool.cancel"
        local token = require ".token.token"
        local burn = require ".pool.burn"
        local pool = require ".pool.pool"
        local swap = require ".pool.swap"
        local utils = require ".utils"
        
        -- Global types
        ---@alias Balances table<string, Bint>
        
        token.init()
        pool.init()
        
        -- *initialize Handlers*
        
        -- token functions
        Handlers.add(
          "info",
          Handlers.utils.hasMatchingTag("Action", "Info"),
          token.info
        )
        
        Handlers.add(
          "balance",
          Handlers.utils.hasMatchingTag("Action", "Balance"),
          balance.balance
        )
        Handlers.add(
          "balances",
          Handlers.utils.hasMatchingTag("Action", "Balances"),
          balance.balances
        )
        Handlers.add(
          "totalSupply",
          Handlers.utils.hasMatchingTag("Action", "Total-Supply"),
          function (msg)
            local res = balance.totalSupply()
        
            ao.send({
              Target = msg.From,
              ["Total-Supply"] = tostring(res),
              Ticker = Ticker,
              Data = tostring(res)
            })
            print(
              outputs.prefix("Total-Supply", msg.From) ..
              Colors.gray ..
              "Total-Supply = " ..
              Colors.blue ..
              tostring(res) ..
              Colors.reset
            )
          end
        )
        
        Handlers.add(
          "transfer",
          Handlers.utils.hasMatchingTag("Action", "Transfer"),
          transfer.transfer
        )
        
        -- AMM read
        Handlers.add(
          "getPair",
          Handlers.utils.hasMatchingTag("Action", "Get-Pair"),
          function (msg)
            local res = pool.getPair()
        
            ao.send({
              Target = msg.From,
              ["Token-A"] = res[1],
              ["Token-B"] = res[2]
            })
            print(
              outputs.prefix("Get-Pair", msg.From) ..
              Colors.gray ..
              "Pair = " ..
              outputs.formatAddress(res[1]) ..
              Colors.gray ..
              "/" ..
              outputs.formatAddress(res[2]) ..
              Colors.reset
            )
          end
        )
        Handlers.add(
          "getReserves",
          Handlers.utils.hasMatchingTag("Action", "Get-Reserves"),
          function (msg)
            local res = pool.getReserves()
            local pair = pool.getPair()
        
            ao.send({
              Target = msg.From,
              [pair[1]] = tostring(res[pair[1]]),
              [pair[2]] = tostring(res[pair[2]])
            })
            print(
              outputs.prefix("Get-Reserves", msg.From) ..
              Colors.gray ..
              "Reserves = [" ..
              outputs.formatAddress(pair[1]) ..
              Colors.gray ..
              "=" ..
              Colors.blue ..
              tostring(res[pair[1]]) ..
              Colors.gray ..
              ", " ..
              outputs.formatAddress(pair[2]) ..
              Colors.gray ..
              "=" ..
              Colors.blue ..
              tostring(res[pair[2]]) ..
              Colors.gray ..
              "]" ..
              Colors.reset
            )
          end
        )
        Handlers.add(
          "K",
          Handlers.utils.hasMatchingTag("Action", "Get-K"),
          function (msg)
            local res = pool.K()
        
            ao.send({
              Target = msg.From,
              K = tostring(res)
            })
            print(
              outputs.prefix("Get-K", msg.From) ..
              Colors.gray ..
              "K = " ..
              Colors.blue ..
              tostring(res) ..
              Colors.reset
            )
          end
        )
        Handlers.add(
          "getPrice",
          Handlers.utils.hasMatchingTag("Action", "Get-Price"),
          pool.getPrice
        )
        Handlers.add(
          "getLPFeePercentage",
          Handlers.utils.hasMatchingTag("Action", "Get-LP-Fee-Percentage"),
          function (msg)
            local res = pool.getLPFeePercentage()
        
            ao.send({
              Target = msg.From,
              ["Fee-Percentage"] = tostring(res)
            })
            print(
              outputs.prefix("Get-LP-Fee-Percentage", msg.From) ..
              Colors.gray ..
              "Fee-Percentage = " ..
              Colors.blue ..
              tostring(res) ..
              Colors.gray ..
              "%" ..
              Colors.reset
            )
          end
        )
        
        -- AMM interactions
        Handlers.add(
          "burn",
          Handlers.utils.hasMatchingTag("Action", "Burn"),
          burn.burn
        )
        Handlers.add(
          "cancel",
          Handlers.utils.hasMatchingTag("Action", "Cancel"),
          cancel.cancel
        )
        
        -- the credit notice handler runs before Swap/Provide
        -- it only checks if the tokens sent are in the pair
        --
        -- if they're not in the pair, it sends them back
        -- in this case, we need to ensure that the Swap/Provide
        -- actions don't run, that is why we add a pattern
        -- to their handlers to check if the sent tokens are in
        -- the AMM token pair
        Handlers.add(
          "creditNotice",
          patterns.continue(Handlers.utils.hasMatchingTag("Action", "Credit-Notice")),
          incoming.creditNotice
        )
        
        -- the following interactions require the user to transfer one
        -- or multiple amounts of tokens to the AMM
        -- because of that, if they fail, these transfers need to be
        -- sent back
        -- "Provide" and "Swap" will let the process continue evaluating
        -- handlers, so we can later verify if any of the interactions
        -- failed and refund the user if needed
        Handlers.add(
          "provide",
          patterns.continue(patterns._and(
            Handlers.utils.hasMatchingTag("Action", "Credit-Notice"),
            Handlers.utils.hasMatchingTag("X-Action", "Provide"),
            function (msg) return utils.includes(msg.From, pool.getPair()) end
          )),
          patterns.catchWrapper(provide.provide)
        )
        Handlers.add(
          "swap",
          patterns.continue(patterns._and(
            Handlers.utils.hasMatchingTag("Action", "Credit-Notice"),
            Handlers.utils.hasMatchingTag("X-Action", "Swap"),
            function (msg) return utils.includes(msg.From, pool.getPair()) end
          )),
          patterns.catchWrapper(swap.swap)
        )
        
        -- IMPORTANT: there is a special variable called "RefundError"
        -- when adding handlers that deal with incoming swaps, it is
        -- necessary to wrap the handler function with the 
        -- "patterns.catchWrapper" wrapper function, to set this global
        -- variable when an error is thrown, so the refund finalizer 
        -- refunds failed swaps, provides, etc. 
        
        -- this handler will refund the user if the provide/swap
        -- interaction errored, like it is mentioned above
        Handlers.add(
          "refundFinalizer",
          patterns._and(
            Handlers.utils.hasMatchingTag("Action", "Credit-Notice"),
            patterns.hasMatchingTagOf("X-Action", { "Provide", "Swap" }),
            function (msg) return utils.includes(msg.From, pool.getPair()) end
          ),
          refund.refund
        )
        
]===]

return AMM_PROCESS_CODE