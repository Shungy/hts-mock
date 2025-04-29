// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.5.0 <0.9.0;
pragma experimental ABIEncoderV2;

library KeyHelper {
    enum KeyType {
        ADMIN,
        KYC,
        FREEZE,
        WIPE,
        SUPPLY,
        FEE,
        PAUSE
    }
}
