# Bark AMM Factory

AO Process `2wGKeNXia3-cpSX9GNpEabFX2LcDw_m1R_huKZ1IFN4`

## Usage
1. Send message `Action = Spawn-AMM` to process containing Token-A, Token-B and Name tag according to Bark spec (Token-A should be the quote token of the pair). Save the message id of this message!
2. Wait a few moments for AMM process to spawn (can poll via Dry-Running `Get-Pending-AMM-Count`, which returns `Pending-AMM-Count`) 
3. Send `Init-AMM` message, this will deploy the code to all pending processes.
4. With the `Get-Process-Id` and the `Original-Message-Id` as a tag you can retreive the process id of the spawned AMM. Alternatively `Get-Latest-Process-Id-For-Deployer` can be used to retreive with the `Deployer` tag, which is the Sender of the first message
5. To seed the AMM with liquidity send two token transactions to the pool with tag `X-Action = 'Provide'`

## AOS example

`__VItE4VkIwLyidE2JCNhkYJ-Zq7SIHYs-Wk-6Gjn40` and `qY9e-nCTdyvK5CMgIWv4LkhA29Entk80fkpPaKvpvtQ` are tokens.

```
> Send({Target = '2wGKeNXia3-cpSX9GNpEabFX2LcDw_m1R_huKZ1IFN4', Action = "Spawn-AMM",  ['Token-A'] = '__VItE4VkIwLyidE2JCNhkYJ-Zq7SIHYs-Wk-6Gjn40', ['Token-B'] = 'qY9e-nCTdyvK5CMgIWv4LkhA29Entk80fkpPaKvpvtQ', Name = 'bark-test12'})
> (wait for response)
> originalMessageId = Inbox[#Inbox].Tags['Original-Message-Id']
> Send({Target = '2wGKeNXia3-cpSX9GNpEabFX2LcDw_m1R_huKZ1IFN4', Action = "Init-AMM"})
> Send({Target = '2wGKeNXia3-cpSX9GNpEabFX2LcDw_m1R_huKZ1IFN4', Action = "Get-Pending-AMM-Count"})
> (wait for response)
> print(Inbox[#Inbox].Tags['Pending-AMM-Count'])
> Send({Target = '2wGKeNXia3-cpSX9GNpEabFX2LcDw_m1R_huKZ1IFN4', Action = "Get-Process-Id", ['Original-Message-Id'] = originalMessageId})
> (wait for response)
> ammProcessId = Inbox[#Inbox].Tags['Process-Id']
> Send({Target = '__VItE4VkIwLyidE2JCNhkYJ-Zq7SIHYs-Wk-6Gjn40', Action = 'Transfer', ['X-Action'] = 'Provide', Quantity = '100000', Recipient = ammProcessId, ['X-Slippage-Tolerance'] = '1' })
> Send({Target = 'qY9e-nCTdyvK5CMgIWv4LkhA29Entk80fkpPaKvpvtQ', Action = 'Transfer', ['X-Action'] = 'Provide', Quantity = '100000', Recipient = ammProcessId, ['X-Slippage-Tolerance'] = '1' })
> (receive a `Provide-Confirmation` message)