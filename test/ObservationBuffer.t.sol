// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ObservationBuffer} from "../src/ObservationBuffer.sol";

/// @notice Differential tests of {ObservationBuffer} against a plain append-only array model.
/// @dev The model is `_model`, a dynamic array that records every accepted write in order. The
///      buffer is expected to expose exactly the last `min(_model.length, 16)` model entries, in
///      order, through every read path.
contract ObservationBufferTest is Test {
    uint256 internal constant CAPACITY = 16;

    ObservationBuffer internal buffer;

    /// @dev Append-only reference model of every accepted write.
    ObservationBuffer.Observation[] internal _model;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        buffer = new ObservationBuffer();
    }

    // ------------------------------------------------------------- helpers

    /// @dev Deterministic but irregular timestamp for write number `i` (0-based), strictly
    ///      increasing in `i` and free of overflow for any `i` a test uses.
    function _timestampFor(uint256 i) internal pure returns (uint256) {
        // Step between 1 and 1_000_000, never zero, so successive timestamps are strictly increasing.
        uint256 step = (uint256(keccak256(abi.encode("ts", i))) % 1_000_000) + 1;
        return 1_700_000_000 + i * 1_000_000 + step;
    }

    /// @dev Full-width pseudo-random value for write number `i`, so values exercise all 256 bits.
    function _valueFor(uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode("value", i)));
    }

    function _write(uint256 timestamp, uint256 value) internal returns (uint256 sequence) {
        sequence = buffer.write(timestamp, value);
        _model.push(ObservationBuffer.Observation({timestamp: timestamp, value: value}));
    }

    function _writeN(uint256 n) internal {
        for (uint256 i = _model.length; i < n; ++i) {
            _write(_timestampFor(i), _valueFor(i));
        }
    }

    function _expectedLength() internal view returns (uint256) {
        return _model.length < CAPACITY ? _model.length : CAPACITY;
    }

    /// @dev Every read path must agree with the model window.
    function _assertMatchesModel() internal {
        uint256 total = _model.length;
        uint256 len = _expectedLength();
        uint256 first = total - len;

        assertEq(buffer.length(), len, "length");
        assertEq(buffer.totalWritten(), total, "totalWritten");
        assertEq(buffer.oldestSequence(), first, "oldestSequence");

        ObservationBuffer.Observation[] memory all = buffer.observations();
        assertEq(all.length, len, "observations().length");

        for (uint256 i; i < len; ++i) {
            ObservationBuffer.Observation memory expected = _model[first + i];
            (uint256 ts, uint256 value) = buffer.get(i);
            assertEq(ts, expected.timestamp, "get(i).timestamp");
            assertEq(value, expected.value, "get(i).value");
            assertEq(all[i].timestamp, expected.timestamp, "observations()[i].timestamp");
            assertEq(all[i].value, expected.value, "observations()[i].value");
            if (i > 0) {
                assertGt(ts, all[i - 1].timestamp, "timestamps not strictly increasing in enumeration");
            }
        }

        if (len == 0) {
            vm.expectRevert(ObservationBuffer.EmptyBuffer.selector);
            buffer.latest();
            vm.expectRevert(ObservationBuffer.EmptyBuffer.selector);
            buffer.oldest();
        } else {
            (uint256 lts, uint256 lval) = buffer.latest();
            assertEq(lts, _model[total - 1].timestamp, "latest.timestamp");
            assertEq(lval, _model[total - 1].value, "latest.value");
            (uint256 ots, uint256 oval) = buffer.oldest();
            assertEq(ots, _model[first].timestamp, "oldest.timestamp");
            assertEq(oval, _model[first].value, "oldest.value");
        }

        // Out-of-range reads: exactly at the boundary and far beyond it.
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.IndexOutOfRange.selector, len, len));
        buffer.get(len);
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.IndexOutOfRange.selector, CAPACITY, len));
        buffer.get(CAPACITY);
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.IndexOutOfRange.selector, type(uint256).max, len));
        buffer.get(type(uint256).max);
    }

    /// @dev Write `n` observations, checking the model after every single write.
    function _runAndCheck(uint256 n) internal {
        _assertMatchesModel();
        for (uint256 i; i < n; ++i) {
            _write(_timestampFor(i), _valueFor(i));
            _assertMatchesModel();
        }
        assertEq(buffer.totalWritten(), n);
        assertEq(buffer.length(), n < CAPACITY ? n : CAPACITY);
    }

    // ---------------------------------------------------------- deployment

    function test_constants() public view {
        assertEq(buffer.CAPACITY(), CAPACITY);
    }

    // ------------------------------------------------ fill levels vs model

    function test_zeroWrites() public {
        _runAndCheck(0);
        assertEq(buffer.observations().length, 0);
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.IndexOutOfRange.selector, 0, 0));
        buffer.get(0);
    }

    function test_oneWrite() public {
        _runAndCheck(1);
        (uint256 ts, uint256 value) = buffer.get(0);
        assertEq(ts, _timestampFor(0));
        assertEq(value, _valueFor(0));
    }

    function test_fifteenWrites_bufferNotYetFull() public {
        _runAndCheck(15);
        assertEq(buffer.length(), 15);
        assertEq(buffer.oldestSequence(), 0);
        // Slot 15 has never been written and is still zero.
        ObservationBuffer.Observation memory empty = buffer.rawSlot(15);
        assertEq(empty.timestamp, 0);
        assertEq(empty.value, 0);
    }

    function test_sixteenWrites_bufferExactlyFull() public {
        _runAndCheck(16);
        assertEq(buffer.length(), 16);
        assertEq(buffer.oldestSequence(), 0);
        // Every physical slot holds the write with the same sequence number.
        for (uint256 s; s < CAPACITY; ++s) {
            ObservationBuffer.Observation memory raw = buffer.rawSlot(s);
            assertEq(raw.timestamp, _timestampFor(s));
            assertEq(raw.value, _valueFor(s));
        }
    }

    function test_seventeenWrites_firstWraparound() public {
        _runAndCheck(17);
        assertEq(buffer.length(), 16);
        assertEq(buffer.oldestSequence(), 1);
        // Logical index 0 is now write #1; write #0 is gone.
        (uint256 ts,) = buffer.get(0);
        assertEq(ts, _timestampFor(1));
        (ts,) = buffer.get(15);
        assertEq(ts, _timestampFor(16));
    }

    function test_hundredWrites_manyWraparounds() public {
        _runAndCheck(100);
        assertEq(buffer.length(), 16);
        assertEq(buffer.oldestSequence(), 84);
        (uint256 ts,) = buffer.get(0);
        assertEq(ts, _timestampFor(84));
        (ts,) = buffer.get(15);
        assertEq(ts, _timestampFor(99));
    }

    // ------------------------------------------------------ rejected writes

    function test_firstWriteAcceptsZeroTimestamp() public {
        _write(0, 123);
        _assertMatchesModel();
        // And zero can never be written again.
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.TimestampNotIncreasing.selector, 0, 0));
        buffer.write(0, 456);
    }

    function test_rejectsEqualTimestamp() public {
        _writeN(3);
        uint256 latestTs = _timestampFor(2);
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.TimestampNotIncreasing.selector, latestTs, latestTs));
        buffer.write(latestTs, 1);
        _assertMatchesModel();
    }

    function test_rejectsOlderTimestamp() public {
        _writeN(3);
        uint256 latestTs = _timestampFor(2);
        vm.expectRevert(
            abi.encodeWithSelector(ObservationBuffer.TimestampNotIncreasing.selector, latestTs - 1, latestTs)
        );
        buffer.write(latestTs - 1, 1);
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.TimestampNotIncreasing.selector, 0, latestTs));
        buffer.write(0, 1);
        _assertMatchesModel();
    }

    function test_rejectedWriteLeavesNoTrace() public {
        _writeN(20);
        uint256 latestTs = _timestampFor(19);
        ObservationBuffer.Observation[] memory before = buffer.observations();
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.TimestampNotIncreasing.selector, latestTs, latestTs));
        buffer.write(latestTs, type(uint256).max);
        ObservationBuffer.Observation[] memory afterwards = buffer.observations();
        assertEq(keccak256(abi.encode(before)), keccak256(abi.encode(afterwards)), "state changed on revert");
        assertEq(buffer.totalWritten(), 20);
        _assertMatchesModel();
    }

    /// @dev The comparison is against the *latest* observation only, not against evicted ones.
    ///      After wraparound a timestamp older than the evicted oldest is still rejected because it
    ///      is also older than the latest.
    function test_rejectionUsesLatestObservationAfterWraparound() public {
        _writeN(40);
        uint256 latestTs = _timestampFor(39);
        uint256 evictedTs = _timestampFor(0);
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.TimestampNotIncreasing.selector, evictedTs, latestTs));
        buffer.write(evictedTs, 1);
        // Strictly greater than latest is accepted even by a single unit.
        _write(latestTs + 1, 7);
        _assertMatchesModel();
    }

    function test_acceptsLargeTimestampJump() public {
        _write(1, 1);
        _write(type(uint256).max - 1, 2);
        _assertMatchesModel();
    }

    /// @dev Documented limitation: writing the maximum timestamp freezes the buffer forever.
    function test_maxTimestampFreezesBuffer() public {
        _write(5, 5);
        _write(type(uint256).max, 9);
        _assertMatchesModel();
        vm.expectRevert(
            abi.encodeWithSelector(
                ObservationBuffer.TimestampNotIncreasing.selector, type(uint256).max, type(uint256).max
            )
        );
        buffer.write(type(uint256).max, 10);
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.TimestampNotIncreasing.selector, 0, type(uint256).max));
        buffer.write(0, 10);
    }

    // ------------------------------------------------------- value domain

    function test_valuesSpanFullUint256() public {
        _write(1, 0);
        _write(2, type(uint256).max);
        _write(3, 1 << 255);
        _write(4, 1);
        _assertMatchesModel();
        (, uint256 v) = buffer.get(1);
        assertEq(v, type(uint256).max);
    }

    // ----------------------------------------------------- overwritten data

    function test_overwrittenDataIsGone() public {
        _writeN(16);
        // Sequence 0 is stored in slot 0 and readable at logical index 0.
        (uint256 ts0, uint256 v0) = buffer.get(0);
        assertEq(ts0, _timestampFor(0));
        assertEq(v0, _valueFor(0));

        _writeN(17);
        // Slot 0 now physically holds sequence 16 ...
        ObservationBuffer.Observation memory raw = buffer.rawSlot(0);
        assertEq(raw.timestamp, _timestampFor(16));
        assertEq(raw.value, _valueFor(16));
        // ... and sequence 0 appears at no logical index.
        for (uint256 i; i < CAPACITY; ++i) {
            (uint256 ts,) = buffer.get(i);
            assertTrue(ts != ts0, "evicted observation still enumerated");
        }
        _assertMatchesModel();
    }

    function test_overwriteRotatesThroughEverySlot() public {
        _writeN(100);
        // With 100 writes, slot s holds the last sequence congruent to s mod 16.
        for (uint256 s; s < CAPACITY; ++s) {
            uint256 expectedSequence = 96 + s < 100 ? 96 + s : 80 + s;
            ObservationBuffer.Observation memory raw = buffer.rawSlot(s);
            assertEq(raw.timestamp, _timestampFor(expectedSequence), "slot holds wrong sequence");
            assertEq(raw.value, _valueFor(expectedSequence), "slot holds wrong value");
        }
        _assertMatchesModel();
    }

    function test_rawSlotOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.SlotOutOfRange.selector, 16, 16));
        buffer.rawSlot(16);
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.SlotOutOfRange.selector, type(uint256).max, 16));
        buffer.rawSlot(type(uint256).max);
    }

    // --------------------------------------------------------- permissions

    function test_permissionless_anyAccountCanWrite() public {
        vm.prank(ALICE);
        _write(10, 1);
        vm.prank(BOB);
        _write(20, 2);
        vm.prank(address(0));
        _write(30, 3);
        _assertMatchesModel();
    }

    function test_emitsObservationWritten() public {
        _writeN(16);
        vm.expectEmit(true, true, true, true, address(buffer));
        emit ObservationBuffer.ObservationWritten(ALICE, 16, 0, _timestampFor(16), _valueFor(16));
        vm.prank(ALICE);
        uint256 sequence = buffer.write(_timestampFor(16), _valueFor(16));
        assertEq(sequence, 16);
    }

    function test_writeReturnsSequence() public {
        for (uint256 i; i < 40; ++i) {
            assertEq(_write(_timestampFor(i), _valueFor(i)), i);
        }
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev Random number of writes (0..100) with random strictly increasing timestamps and full
    ///      width values; every read path must match the array model.
    function testFuzz_matchesModel(uint8 writesRaw, uint128 startTimestamp, bytes32 seed) public {
        uint256 writes = uint256(writesRaw) % 101;
        uint256 ts = startTimestamp;
        for (uint256 i; i < writes; ++i) {
            bytes32 r = keccak256(abi.encode(seed, i));
            // Step in [1, 2^64]; total drift stays far below 2^256.
            ts += (uint256(r) % (1 << 64)) + 1;
            _write(ts, uint256(keccak256(abi.encode(r, "v"))));
        }
        _assertMatchesModel();
    }

    function testFuzz_rejectsNonIncreasingTimestamp(uint256 latestTs, uint256 badTs, uint256 value) public {
        badTs = bound(badTs, 0, latestTs);
        _write(latestTs, value);
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.TimestampNotIncreasing.selector, badTs, latestTs));
        buffer.write(badTs, value);
        _assertMatchesModel();
    }

    function testFuzz_acceptsStrictlyGreaterTimestamp(uint256 latestTs, uint256 goodTs, uint256 value) public {
        latestTs = bound(latestTs, 0, type(uint256).max - 1);
        goodTs = bound(goodTs, latestTs + 1, type(uint256).max);
        _write(latestTs, value);
        _write(goodTs, ~value);
        _assertMatchesModel();
    }

    function testFuzz_outOfRangeReadReverts(uint8 writesRaw, uint256 index) public {
        uint256 writes = uint256(writesRaw) % 101;
        _writeN(writes);
        uint256 len = writes < CAPACITY ? writes : CAPACITY;
        index = bound(index, len, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ObservationBuffer.IndexOutOfRange.selector, index, len));
        buffer.get(index);
    }

    // ----------------------------------------------------------------- gas

    /// @dev Gas of `write` must stay bounded and must not grow as the buffer fills; overwrites
    ///      (writes 17..100) must cost no more than first-time writes (writes 1..16). Gas of
    ///      `get` must not depend on the logical index or on the fill level.
    function test_gasIsBoundedAsBufferFills() public {
        uint256 maxFirstFill;
        uint256 minOverwrite = type(uint256).max;
        uint256 maxOverwrite;
        uint256[100] memory gasUsed;

        for (uint256 i; i < 100; ++i) {
            uint256 ts = _timestampFor(i);
            uint256 value = _valueFor(i);
            uint256 before = gasleft();
            buffer.write(ts, value);
            uint256 used = before - gasleft();
            gasUsed[i] = used;
            if (i < CAPACITY) {
                if (used > maxFirstFill) maxFirstFill = used;
            } else {
                if (used < minOverwrite) minOverwrite = used;
                if (used > maxOverwrite) maxOverwrite = used;
            }
        }

        console2.log("write gas, write #1 (empty buffer):        ", gasUsed[0]);
        console2.log("write gas, write #2 (one stored):          ", gasUsed[1]);
        console2.log("write gas, write #16 (fills the buffer):   ", gasUsed[15]);
        console2.log("write gas, write #17 (first overwrite):    ", gasUsed[16]);
        console2.log("write gas, write #100:                     ", gasUsed[99]);
        console2.log("write gas, max over writes #1..#16:        ", maxFirstFill);
        console2.log("write gas, min/max over writes #17..#100:  ", minOverwrite, maxOverwrite);

        // Hard bound for any write: far below the block gas limit, no loops, at most three
        // storage slots touched. Measured: ~96k for the very first write, ~77k while filling,
        // ~43k per overwrite (see README, "Gas behaviour").
        for (uint256 i; i < 100; ++i) {
            assertLt(gasUsed[i], 150_000, "write gas exceeds bound");
        }
        // Overwrites never cost more than first-time writes.
        assertLe(maxOverwrite, maxFirstFill, "overwrite costs more than initial fill");
        // Overwrite cost is flat: it does not drift with the number of wraparounds. Calldata
        // encoding of different numbers accounts for a few hundred gas of jitter at most.
        assertLe(maxOverwrite - minOverwrite, 500, "overwrite gas drifts with fill");

        // Reads: constant cost regardless of logical index.
        uint256 minRead = type(uint256).max;
        uint256 maxRead;
        for (uint256 i; i < CAPACITY; ++i) {
            uint256 before = gasleft();
            buffer.get(i);
            uint256 used = before - gasleft();
            if (used < minRead) minRead = used;
            if (used > maxRead) maxRead = used;
        }
        console2.log("get gas, min/max over logical indices 0..15:", minRead, maxRead);
        assertLt(maxRead, 20_000, "read gas exceeds bound");
        assertLe(maxRead - minRead, 300, "read gas depends on index");
    }

    function test_gasOfObservationsIsBoundedWhenFull() public {
        _writeN(100);
        uint256 before = gasleft();
        buffer.observations();
        uint256 used = before - gasleft();
        console2.log("observations() gas when full:", used);
        assertLt(used, 120_000, "observations() gas exceeds bound");
    }
}
