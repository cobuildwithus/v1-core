// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { IArbitrator } from "./IArbitrator.sol";
import { ISubmissionDepositStrategy } from "./ISubmissionDepositStrategy.sol";

interface IGeneralizedTCRConfig {
    struct RegistryPolicy {
        bytes arbitratorExtraData;
        string registrationMetaEvidence;
        string clearingMetaEvidence;
        uint256 submissionBaseDeposit;
        uint256 removalBaseDeposit;
        uint256 submissionChallengeBaseDeposit;
        uint256 removalChallengeBaseDeposit;
        uint256 challengePeriodDuration;
    }

    struct RegistryConfig {
        IArbitrator arbitrator;
        IVotes votingToken;
        ISubmissionDepositStrategy submissionDepositStrategy;
        RegistryPolicy registryPolicy;
    }
}
