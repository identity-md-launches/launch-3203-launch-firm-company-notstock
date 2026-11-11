// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "../test/vendor/forge-std/Script.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {LpGovernor} from "../src/LpGovernor.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {VenueV3} from "../src/VenueV3.sol";
import {VenueV4} from "../src/VenueV4.sol";
import {DeskSwap} from "../src/DeskSwap.sol";

/// @notice Calls LpDesk.deployModule for every module after the launch (anyone may; once per kind).
/// Usage: forge script script/DeployModules.s.sol --sig "deploy(address)" <LpDesk> --rpc-url <base> --broadcast
/// Verification input per module: the source file under src/, compiler 0.8.26, settings of
/// foundry.toml (via_ir, optimizer runs 1, evm cancun, bytecode_hash none), no constructor arguments.
contract DeployModules is Script {
    function deploy(address lpDesk) public {
        LpDesk desk = LpDesk(lpDesk);
        vm.startBroadcast();
        deployAll(desk);
        vm.stopBroadcast();
    }

    /// @dev Deploys every module not yet deployed, in order; safe to re-run.
    function deployAll(LpDesk desk) public {
        if (!desk.moduleDeployed(desk.MODULE_GOVERNOR())) {
            desk.deployModule(desk.MODULE_GOVERNOR(), type(LpGovernor).creationCode);
        }
        if (!desk.moduleDeployed(desk.MODULE_GUARD())) {
            desk.deployModule(desk.MODULE_GUARD(), type(PriceGuard).creationCode);
        }
        if (!desk.moduleDeployed(desk.MODULE_VENUE_V3())) {
            desk.deployModule(desk.MODULE_VENUE_V3(), type(VenueV3).creationCode);
        }
        if (!desk.moduleDeployed(desk.MODULE_VENUE_V4())) {
            desk.deployModule(desk.MODULE_VENUE_V4(), type(VenueV4).creationCode);
        }
        if (!desk.moduleDeployed(desk.MODULE_SWAP())) {
            desk.deployModule(desk.MODULE_SWAP(), type(DeskSwap).creationCode);
        }
    }
}
