// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "../ECDSA.sol";

contract CheckLambda {
    function findSigner(
        address[] calldata addressesToTest,
        uint256 chainId,
        uint256 maxOILong,
        uint256 maxOIShort,
        uint256 timestamp,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external pure returns (address matchAddress, address recoveredSigner) {
        for (uint256 i; i < addressesToTest.length; ++i) {
            bytes32 digest = keccak256(abi.encodePacked(addressesToTest[i], chainId, maxOILong, maxOIShort, timestamp));
            recoveredSigner = ECDSA.recover(digest, v, r, s);
            if (recoveredSigner == 0x8E221f2eaF11eba2CA1fF2DEDd38432673Ee4938 || recoveredSigner == 0x5B2a9529BBEdaaf2eA3DfD0B829ED43Cd708b7D6) {
                return (addressesToTest[i], recoveredSigner);
            }
        }
    }
}
