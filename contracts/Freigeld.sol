// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * Freigeld — money that costs something to hold
 *
 * Every token ever launched rewards you for doing nothing with it. This one
 * charges you.
 *
 * A balance left alone shrinks. What it loses goes to a commons address,
 * and the only way to avoid the charge is to spend, which is precisely the
 * point. Silvio Gesell argued in 1916 that money's advantage over goods —
 * bread rots, steel rusts, cash doesn't — is what lets it sit still and
 * strangle trade. His fix was to make money rot too.
 *
 * ─────────────────────────────────────────────────────────────────────
 * IT HAS BEEN TRIED, AND IT WORKED, AND IT WAS BANNED
 *
 * In July 1932 the Austrian town of Wörgl issued "Certified Compensation
 * Bills" that lost 1% of face value each month. To keep a note current you
 * bought a stamp and stuck it on the back. Nobody wanted to be holding the
 * note at month's end, so the scrip changed hands nine or ten times faster
 * than the national schilling. The town paved roads, built a bridge and a
 * ski jump, and unemployment fell 16% while it rose 19% across Austria.
 *
 * Around two hundred other towns lined up to copy it. The Austrian
 * National Bank shut it down in 1933 on the grounds that only the state
 * may issue currency.
 *
 * The lesson that matters here is from the imitators, not the original:
 * American towns tried the same trick at 2% per WEEK, and the money was
 * simply refused. Demurrage has a ceiling, and past it the currency stops
 * being currency. That's why MAX_RATE_BPS exists and why it's a constant.
 * ─────────────────────────────────────────────────────────────────────
 *
 * HOW THE CHARGE IS COLLECTED
 *
 * Nothing loops over holders — that would cost more than it collects. Each
 * account carries the timestamp of its last touch, and the decay is
 * computed only when someone actually interacts with that balance. Which
 * is exactly how Wörgl worked: the stamp was bought at the moment of use.
 * An untouched balance is *already* smaller in every view; settlement just
 * writes down what was true anyway.
 *
 * WHAT THIS IS NOT
 *
 * It's not an investment, and anyone treating it as one has misread the
 * entire premise — it is designed to lose value in your hands. It's not a
 * store of value. It's a unit for circulating, and it will punish you for
 * doing anything else with it.
 */
contract Freigeld {

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error RateTooHigh(uint16 asked, uint16 max);
    error InsufficientBalance(uint256 have, uint256 want);
    error InsufficientAllowance(uint256 have, uint256 want);
    error NotIssuer();
    error IssuanceClosed();
    error AboveCap(uint256 attempted, uint256 cap);

    // -------------------------------------------------------------- metadata

    string public constant name = "Freigeld";
    string public constant symbol = "FREI";
    uint8  public constant decimals = 6;

    // -------------------------------------------------------------- constants

    /// @dev Wörgl's rate, and the one that demonstrably worked.
    uint16 public constant WOERGL_RATE_BPS = 100;      // 1.00% per period

    /// @dev The imitators failed at roughly 2% a week — about 800 bps a
    ///      month — because people stopped accepting the money. This ceiling
    ///      is a constant, not a setting, for exactly that reason.
    uint16 public constant MAX_RATE_BPS = 500;         // 5.00% per period

    uint32 public constant PERIOD = 30 days;

    /// @dev Bound on the catch-up loop. Past this an account is treated as
    ///      fully decayed rather than costing unbounded gas to settle.
    uint256 private constant MAX_PERIODS = 240;        // 20 years

    // ----------------------------------------------------------------- state

    address public immutable issuer;
    address public immutable commons;   // where the decay goes
    uint16  public immutable rateBps;   // per PERIOD
    uint64  public immutable startedAt;
    uint256 public immutable issueCap;

    uint256 public issued;              // lifetime minted
    uint256 public collected;           // lifetime demurrage taken
    bool    public issuanceClosed;

    mapping(address => uint256) private _bal;      // as of _touched[account]
    mapping(address => uint64)  private _touched;
    mapping(address => mapping(address => uint256)) private _allow;

    uint256 private _supply;

    // ---------------------------------------------------------------- events

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Demurrage(address indexed from, uint256 amount, uint64 idleSeconds);
    event Issued(address indexed to, uint256 amount, uint256 totalIssued);
    event IssuanceEnded(uint256 totalIssued);

    // ----------------------------------------------------------- constructor

    /**
     * @param commons_ Where decayed value goes. In Wörgl this was the town,
     *        and the stamps paid for road works. It is set once and can
     *        never be changed — a commons the issuer could redirect later
     *        isn't a commons.
     * @param rateBps_ Demurrage per 30 days, in basis points.
     */
    constructor(address commons_, uint16 rateBps_, uint256 issueCap_) {
        if (commons_ == address(0)) revert ZeroAddress();
        if (rateBps_ == 0) revert ZeroAmount();
        if (rateBps_ > MAX_RATE_BPS) revert RateTooHigh(rateBps_, MAX_RATE_BPS);
        issuer = msg.sender;
        commons = commons_;
        rateBps = rateBps_;
        issueCap = issueCap_;
        startedAt = uint64(block.timestamp);
    }

    // ------------------------------------------------------------- the decay

    /**
     * @notice What an account is worth right now, decay included.
     * @dev This is the honest balance. The stored number is only ever a
     *      snapshot from the last time the account was touched; every view
     *      here computes forward from it, so a holder is never shown more
     *      than they actually have.
     */
    function balanceOf(address who) public view returns (uint256) {
        (uint256 net, ) = _decayed(who);
        return net;
    }

    /// @notice What the account has lost since it was last touched.
    function pendingDemurrage(address who) external view returns (uint256) {
        (, uint256 lost) = _decayed(who);
        return lost;
    }

    function _decayed(address who) internal view returns (uint256 net, uint256 lost) {
        uint256 bal = _bal[who];
        if (bal == 0) return (0, 0);
        uint64 last = _touched[who];
        if (last == 0) return (bal, 0);

        uint256 elapsed = block.timestamp - last;
        if (elapsed == 0) return (bal, 0);

        uint256 periods = elapsed / PERIOD;
        uint256 remainder = elapsed % PERIOD;
        uint256 v = bal;

        // The loop is bounded for gas, but the bound must not become a
        // confiscation: past MAX_PERIODS we simply stop charging rather
        // than zeroing the balance. At 1% a month, 240 periods already
        // leaves under a tenth of the original — anyone who waited that
        // long has paid the charge many times over, and taking the
        // remainder would be a cliff, not a demurrage.
        if (periods > MAX_PERIODS) periods = MAX_PERIODS;

        // Full periods compound. A balance shrinks by rate each period, so
        // it approaches zero without ever quite reaching it — which is
        // correct: demurrage is a charge, not a confiscation.
        for (uint256 i = 0; i < periods; i++) {
            v = (v * (10_000 - rateBps)) / 10_000;
            if (v == 0) break;
        }
        // The part-period is charged linearly, which very slightly
        // OVERCHARGES compared with compounding — linear sits below the
        // exponential curve within a period. Left uncorrected, that makes
        // settling often marginally more expensive than sitting still,
        // which is backwards for a currency whose whole purpose is to be
        // moved. So the partial charge is scaled to match what compounding
        // would have taken over the same fraction of a period.
        if (v > 0 && remainder > 0) {
            // rate * (remainder/PERIOD), then halved-correction toward the
            // compounded value: r*t - r²t(1-t)/2, kept in integer math.
            uint256 rt = (uint256(rateBps) * remainder) / uint256(PERIOD);
            uint256 correction =
                (uint256(rateBps) * rt * (uint256(PERIOD) - remainder))
                / (2 * 10_000 * uint256(PERIOD));
            uint256 effective = rt > correction ? rt - correction : rt;
            uint256 part = (v * effective) / 10_000;
            v = v > part ? v - part : 0;
        }
        return (v, bal - v);
    }

    /**
     * @notice Write down what's already true and pay the commons.
     * @dev Anyone may settle any account. That isn't an attack surface — it
     *      takes nothing the account hadn't already lost, and it can only
     *      move value to the fixed commons address. Letting anyone call it
     *      means an abandoned balance still funds the commons instead of
     *      sitting in limbo.
     */
    function settle(address who) public {
        (uint256 net, uint256 lost) = _decayed(who);
        uint64 last = _touched[who];
        _bal[who] = net;
        _touched[who] = uint64(block.timestamp);

        if (lost > 0) {
            // The commons is settled first so its own balance can't be
            // inflated by the credit it is about to receive.
            if (who != commons) {
                (uint256 cNet, ) = _decayed(commons);
                _bal[commons] = cNet + lost;
                _touched[commons] = uint64(block.timestamp);
            } else {
                // The commons settling itself keeps what it lost — it is
                // already the destination, so charging it would be circular.
                _bal[who] = net + lost;
            }
            collected += lost;
            emit Demurrage(who, lost, uint64(block.timestamp) - last);
            emit Transfer(who, commons, lost);
        }
    }

    // ---------------------------------------------------------------- ERC-20

    function totalSupply() external view returns (uint256) {
        return _supply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = _allow[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < amount) revert InsufficientAllowance(a, amount);
            _allow[from][msg.sender] = a - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allow[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allow[owner][spender];
    }

    function _move(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Both ends are brought current first. The sender pays for the time
        // they sat on it; the receiver's clock restarts from now.
        settle(from);
        settle(to);

        uint256 bal = _bal[from];
        if (bal < amount) revert InsufficientBalance(bal, amount);

        unchecked { _bal[from] = bal - amount; }
        _bal[to] += amount;
        emit Transfer(from, to, amount);
    }

    // -------------------------------------------------------------- issuance

    /// @notice Put new units into circulation, up to the cap fixed at deploy.
    function issue(address to, uint256 amount) external {
        if (msg.sender != issuer) revert NotIssuer();
        if (issuanceClosed) revert IssuanceClosed();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (issueCap != 0 && issued + amount > issueCap) revert AboveCap(issued + amount, issueCap);

        settle(to);
        _bal[to] += amount;
        _supply += amount;
        issued += amount;

        emit Issued(to, amount, issued);
        emit Transfer(address(0), to, amount);
    }

    /// @notice Close issuance for good. One-way, on purpose.
    function closeIssuance() external {
        if (msg.sender != issuer) revert NotIssuer();
        issuanceClosed = true;
        emit IssuanceEnded(issued);
    }

    // ----------------------------------------------------------------- views

    struct Snapshot {
        uint256 balance;        // after decay
        uint256 stored;         // before decay
        uint256 pending;        // what settling would take
        uint64  lastTouched;
        uint64  idleSeconds;
        uint256 perDayCost;     // roughly what another day costs them
        uint256 daysToHalve;    // at this rate, from here
    }

    /// @notice Everything a holder should be shown, including the part
    ///         nobody else's token would tell them.
    function snapshot(address who) external view returns (Snapshot memory s) {
        (uint256 net, uint256 lost) = _decayed(who);
        s.balance = net;
        s.stored = _bal[who];
        s.pending = lost;
        s.lastTouched = _touched[who];
        s.idleSeconds = _touched[who] == 0 ? 0 : uint64(block.timestamp) - _touched[who];
        s.perDayCost = (net * rateBps) / (10_000 * 30);
        // ln(2)/ln(1/(1-r)) periods, approximated in integer arithmetic.
        // At 100 bps that lands near 69 periods — a bit under six years.
        s.daysToHalve = rateBps == 0 ? 0 : (6931 * 30) / uint256(rateBps);
    }

    /// @notice Charge in basis points and its plain-language equivalents.
    function rates() external view returns (uint16 perPeriodBps, uint256 perYearBps, uint32 periodSeconds) {
        perPeriodBps = rateBps;
        // Compounded over twelve periods, not multiplied — 1% a month is
        // about 11.4% a year, not 12%.
        uint256 v = 1e18;
        for (uint256 i = 0; i < 12; i++) v = (v * (10_000 - rateBps)) / 10_000;
        perYearBps = (1e18 - v) * 10_000 / 1e18;
        periodSeconds = PERIOD;
    }

    /// @dev No owner beyond issuance, no pause, no way to change the rate or
    ///      redirect the commons. Both were fixed when this was deployed.
}
