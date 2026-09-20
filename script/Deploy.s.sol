// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {PaxelRegistry} from "../src/PaxelRegistry.sol";
import {PaxelEventLog} from "../src/PaxelEventLog.sol";

/// @notice Deploys PaxelRegistry and PaxelEventLog to any network, driven by environment variables.
///
///           RPC_URL            RPC endpoint, passed on the command line as --rpc-url $RPC_URL
///           PRIVATE_KEY        deployer key. It becomes DEFAULT_ADMIN_ROLE on the registry.
///                              Optional for a dry run: pass --sender <address> instead
///           CHAIN_ID           expected chain id. The script aborts if the RPC reports a different one
///           DEPLOY_NETWORK     name for deployments/<DEPLOY_NETWORK>.json (default anvil)
///           NETWORK_NAME       network label for the web config (default DEPLOY_NETWORK)
///           EXPLORER_BASE_URL  explorer base URL recorded in the export (default empty)
///
///         Dry run (simulation only):   forge script script/Deploy.s.sol --rpc-url $RPC_URL
///         Broadcast:                   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
///
///         deployments/<DEPLOY_NETWORK>.json is written only when the run actually broadcasts.
contract Deploy is Script {
    function run() external returns (PaxelRegistry registry, PaxelEventLog eventLog) {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        uint256 expectedChainId = vm.envUint("CHAIN_ID");
        require(block.chainid == expectedChainId, "CHAIN_ID does not match the RPC");

        string memory deployName = vm.envOr("DEPLOY_NETWORK", string("anvil"));
        _requireSafeName(deployName);

        if (deployerKey != 0) vm.startBroadcast(deployerKey);
        else vm.startBroadcast();
        registry = new PaxelRegistry();
        eventLog = new PaxelEventLog(registry);
        vm.stopBroadcast();

        address deployer = deployerKey != 0 ? vm.addr(deployerKey) : msg.sender;
        require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), deployer), "deployer is not admin");
        require(address(eventLog.registry()) == address(registry), "event log wired to wrong registry");

        console2.log("Deployer (admin)   ", deployer);
        console2.log("Chain id           ", block.chainid);
        console2.log("PaxelRegistry      ", address(registry));
        console2.log("PaxelEventLog      ", address(eventLog));

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            _export(deployName, deployer, address(registry), address(eventLog));
        } else {
            console2.log("Dry run: nothing sent, deployments file not written. Add --broadcast to deploy.");
        }
    }

    /// @dev Writes deployments/<deployName>.json with the values the web config needs.
    function _export(string memory deployName, address deployer, address registry, address eventLog) internal {
        string memory nl = "\n";
        string memory head = string.concat(
            "{",
            nl,
            '  "network": "',
            vm.envOr("NETWORK_NAME", deployName),
            '",',
            nl,
            '  "chainId": ',
            vm.toString(block.chainid),
            ",",
            nl,
            '  "deployer": "',
            vm.toString(deployer),
            '",',
            nl
        );
        string memory body = string.concat(
            '  "passportRegistry": "',
            vm.toString(registry),
            '",',
            nl,
            '  "eventLog": "',
            vm.toString(eventLog),
            '",',
            nl,
            '  "accessControl": "',
            vm.toString(registry),
            '",',
            nl
        );
        string memory tail =
            string.concat('  "explorerBaseUrl": "', vm.envOr("EXPLORER_BASE_URL", string("")), '"', nl, "}", nl);
        string memory path = string.concat("deployments/", deployName, ".json");
        vm.writeFile(path, string.concat(head, body, tail));
        console2.log("Wrote", path);
    }

    /// @dev Keeps the output path inside deployments/.
    function _requireSafeName(string memory name) internal pure {
        bytes memory b = bytes(name);
        require(b.length > 0 && b.length <= 32, "DEPLOY_NETWORK length");
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-" || c == "_";
            require(ok, "DEPLOY_NETWORK must be lowercase letters, digits, - or _");
        }
    }
}
