// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ObservationBuffer
/// @notice A permissionless ring buffer that keeps the latest 16 (timestamp, value) observations.
/// @dev Behaviour, stated exactly:
///
///  * Anyone may call {write}. There is no owner, no pause and no upgrade path.
///  * A write is accepted if the buffer is empty or its timestamp is strictly greater than the
///    timestamp of the newest stored observation. Otherwise it reverts with
///    {TimestampNotIncreasing}. Timestamps and values are caller supplied `uint256`s; the contract
///    never reads `block.timestamp` and imposes no upper bound on either field.
///  * Storage is a fixed array of {CAPACITY} slots written round-robin. Once 16 observations are
///    stored the 17th write overwrites the oldest one, and so on. Overwritten data is gone.
///  * Reads use logical indices: index 0 is always the oldest observation still stored and
///    `length() - 1` is always the newest, regardless of how many wraparounds have happened.
///    Reading an index `>= length()` reverts with {IndexOutOfRange}.
///  * Every accepted write costs a bounded, fill-independent amount of gas: at most three storage
///    slots are written and one is read, whatever the fill level. Overwrites are cheaper than
///    first-time writes because the slots are already non-zero.
///
/// Because timestamps are caller supplied and unbounded, any caller can move the "latest"
/// timestamp arbitrarily far forward (up to `type(uint256).max`, after which no write can ever be
/// accepted again). A deployment therefore only makes sense where every writer is trusted to
/// submit honest timestamps, or where the buffer is disposable. See the README.
contract ObservationBuffer {
    /// @notice One stored observation.
    struct Observation {
        uint256 timestamp;
        uint256 value;
    }

    /// @notice Number of observations the buffer retains.
    uint256 public constant CAPACITY = 16;

    /// @dev Physical ring storage. Slot `s` holds the observation with sequence `s (mod CAPACITY)`.
    Observation[CAPACITY] private _slots;

    /// @dev Total number of accepted writes since deployment. Also the sequence number of the
    /// next write. Practically cannot overflow (2^256 writes).
    uint256 private _written;

    /// @notice Emitted for every accepted write.
    /// @param writer   The account that submitted the observation.
    /// @param sequence Zero-based global sequence number of the write.
    /// @param slot     Physical slot (`sequence % CAPACITY`) that was written.
    /// @param timestamp The stored timestamp.
    /// @param value    The stored value.
    event ObservationWritten(
        address indexed writer, uint256 indexed sequence, uint256 slot, uint256 timestamp, uint256 value
    );

    /// @notice The submitted timestamp is not strictly greater than the newest stored one.
    error TimestampNotIncreasing(uint256 timestamp, uint256 latestTimestamp);

    /// @notice The requested logical index is not currently populated.
    error IndexOutOfRange(uint256 index, uint256 length);

    /// @notice The requested physical slot does not exist.
    error SlotOutOfRange(uint256 slot, uint256 capacity);

    /// @notice The buffer holds no observations.
    error EmptyBuffer();

    // ------------------------------------------------------------------ writes

    /// @notice Store a new observation, overwriting the oldest one once the buffer is full.
    /// @dev Reverts with {TimestampNotIncreasing} unless the buffer is empty or
    ///      `timestamp > latest().timestamp`. Anyone may call this.
    /// @param timestamp Caller supplied timestamp. Must exceed the newest stored timestamp.
    /// @param value     Arbitrary `uint256` payload.
    /// @return sequence Zero-based global sequence number assigned to this write.
    function write(uint256 timestamp, uint256 value) external returns (uint256 sequence) {
        uint256 written = _written;
        if (written != 0) {
            uint256 latestTimestamp = _slots[(written - 1) % CAPACITY].timestamp;
            if (timestamp <= latestTimestamp) {
                revert TimestampNotIncreasing(timestamp, latestTimestamp);
            }
        }
        uint256 slot = written % CAPACITY;
        _slots[slot] = Observation({timestamp: timestamp, value: value});
        _written = written + 1;
        emit ObservationWritten(msg.sender, written, slot, timestamp, value);
        return written;
    }

    // ------------------------------------------------------------------- reads

    /// @notice Number of observations currently stored: `min(totalWritten(), CAPACITY)`.
    function length() public view returns (uint256) {
        return _length(_written);
    }

    /// @notice Total number of accepted writes since deployment, including overwritten ones.
    function totalWritten() external view returns (uint256) {
        return _written;
    }

    /// @notice Global sequence number of the observation at logical index 0.
    /// @dev Equals `totalWritten() - length()`. Zero until the first wraparound.
    function oldestSequence() external view returns (uint256) {
        uint256 written = _written;
        return written - _length(written);
    }

    /// @notice Read an observation by logical index, 0 being the oldest stored and `length() - 1`
    ///         the newest. Enumeration order is oldest to newest before and after wraparound.
    /// @dev Reverts with {IndexOutOfRange} when `index >= length()`.
    function get(uint256 index) public view returns (uint256 timestamp, uint256 value) {
        uint256 written = _written;
        uint256 len = _length(written);
        if (index >= len) revert IndexOutOfRange(index, len);
        Observation storage observation = _slots[(written - len + index) % CAPACITY];
        return (observation.timestamp, observation.value);
    }

    /// @notice The newest stored observation. Reverts with {EmptyBuffer} when nothing is stored.
    function latest() external view returns (uint256 timestamp, uint256 value) {
        uint256 len = _length(_written);
        if (len == 0) revert EmptyBuffer();
        return get(len - 1);
    }

    /// @notice The oldest stored observation. Reverts with {EmptyBuffer} when nothing is stored.
    function oldest() external view returns (uint256 timestamp, uint256 value) {
        if (_written == 0) revert EmptyBuffer();
        return get(0);
    }

    /// @notice All stored observations, oldest first. Length is `length()`, at most {CAPACITY}.
    function observations() external view returns (Observation[] memory list) {
        uint256 written = _written;
        uint256 len = _length(written);
        list = new Observation[](len);
        uint256 first = written - len;
        for (uint256 i; i < len; ++i) {
            list[i] = _slots[(first + i) % CAPACITY];
        }
    }

    /// @notice Raw contents of a physical slot, including stale data that has been logically
    ///         evicted or slots that were never written (all zero). Exposed for auditing only;
    ///         use {get} for ordered reads.
    /// @dev Reverts with {SlotOutOfRange} when `slot >= CAPACITY`.
    function rawSlot(uint256 slot) external view returns (Observation memory observation) {
        if (slot >= CAPACITY) revert SlotOutOfRange(slot, CAPACITY);
        return _slots[slot];
    }

    // --------------------------------------------------------------- internals

    function _length(uint256 written) private pure returns (uint256) {
        return written < CAPACITY ? written : CAPACITY;
    }
}
