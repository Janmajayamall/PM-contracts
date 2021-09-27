%lang starknet
%builtins pedersen range_check ecdsa

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.math import assert_nn, assert_le, assert_not_zero, assert_nn_le, assert_not_equal, unsigned_div_rem
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.signature import (verify_ecdsa_signature)
from starkware.starknet.common.messages import send_message_to_l1
from starkware.starknet.common.storage import Storage
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.registers import get_fp_and_pc


struct Market:
    member market_id: felt
    member market_identifier: felt
    member timestamp: felt
    member state: felt
    member total_vol: felt
    member total_up: felt
    member total_down: felt
    member ruling: felt
end 

# states:
# 0 -> invalid state
# 1 -> active state
# 2 -> resolving
# 3 -> resolved
# 4 -> expired
# 1 -> 4 possible (used for expiration)
# 1 -> 2 possible (change to resolving)
# 2 -> 3 possible (change to resolved)
# goint back to smaller number & rest of state transitions - not possible

# ruling:
# 0 -> in favor of down vote
# 1 -> in favor of up vote
# 2 -> unresolved

struct Bet:
    member market_id: felt
    member user: felt
    member amount: felt
    member direction: felt
end
    
@storage_var 
func markets(id: felt) -> (res: Market):
end

@storage_var
func bets(market_id: felt, user: felt) -> (bet: Bet):
end

@storage_var
func balances(user: felt) -> (amount: felt):
end

@storage_var
func market_index() -> (index: felt):
end

@storage_var
func _l1_contract() -> (res: felt):
end

@storage_var
func _owner() -> (res: felt):
end

@storage_var
func initialized() -> (res: felt):
end

const AMOUNT_MUL = 1000000000000000000


func _smaller{
    range_check_ptr}(a: felt, b: felt)->(ans: felt):
    let (ans) = is_le(a, b)
    if ans == 1:
        return (ans=a)
    else:
        return (ans=b)
    end
end

func _dist_money{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    }(winning_vol: felt, losing_vol: felt, user_amount: felt, user: felt, user_win: felt) -> () :
    alloc_locals

    assert_nn_le(user_win, 1) # user_win can only be {0, 1}

    # zero checks
    if winning_vol == 0:
        if user_amount != 0:
            let (user_balance) = balances.read(user)
            balances.write(user, user_balance + user_amount)
            return ()
        else:
            return ()
        end
    end

    if losing_vol == 0:
        if user_amount != 0:
            let (user_balance) = balances.read(user)
            balances.write(user, user_balance + user_amount)
            return ()
        else:
            return ()
        end
    end
     
    let (local prize_vol) = _smaller(losing_vol, winning_vol)
    let (local user_balance) = balances.read(user)

    if user_win == 1:
        # calculate user win amount
        let (user_win_amount, _) = unsigned_div_rem((user_amount * prize_vol), winning_vol)
        # final payout
        tempvar user_final_amount = user_win_amount + user_amount
        balances.write(user, user_balance + user_final_amount)

        # rebinding ptrs, thus removing binding ambiguity
        tempvar range_check_ptr = range_check_ptr
        tempvar storage_ptr = storage_ptr
        tempvar pedersen_ptr = pedersen_ptr
    else:
        # refund excess bet amount, if any
        tempvar remaining_vol = losing_vol - prize_vol
        let (user_refund_amount, _) = unsigned_div_rem((user_amount * remaining_vol), losing_vol)
        # refund amount
        balances.write(user, user_balance + user_refund_amount)

        # rebinding ptrs, thus removing binding ambiguity
        tempvar range_check_ptr = range_check_ptr
        tempvar storage_ptr = storage_ptr
        tempvar pedersen_ptr = pedersen_ptr
    end
    return ()
end

func _claim_rewards{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
    }(market_ids_len: felt, market_ids: felt*, user: felt) -> ():  
    alloc_locals
    if market_ids_len == 0:
        return ()
    end

    let (local market) = markets.read([market_ids])
    assert market.market_id = [market_ids] # confirms that market exists
    assert market.state = 3 # confirms that market is resolved
    assert_nn_le(market.ruling, 2) # confirms that market ruling is valid

    let (local bet) = bets.read([market_ids], user)
    assert bet.market_id = [market_ids] # confirms that user placed a bet
    assert bet.user = user # confirms that user placed a bet
    assert_nn_le(bet.direction, 1) # confirms that bet direction is valid

    # user's share
    # return user's money if ruling is 2 (i.e. unresolved)
    if market.ruling == 2:
        let (user_balance) = balances.read(user=user)
        balances.write(user, user_balance + bet.amount)

        tempvar storage_ptr = storage_ptr  
        tempvar pedersen_ptr = pedersen_ptr
        tempvar range_check_ptr = range_check_ptr 
    else:
        tempvar storage_ptr = storage_ptr  
        tempvar pedersen_ptr = pedersen_ptr
        tempvar range_check_ptr = range_check_ptr 
    end

    if market.ruling == 0:
        if bet.direction == 0:
            # user won - return their bet amount & winning share
            _dist_money(market.total_down, market.total_up, bet.amount, user, 1)

            # rebinding ptrs, thus removing binding ambiguity
            tempvar range_check_ptr = range_check_ptr     
            tempvar storage_ptr = storage_ptr  
            tempvar pedersen_ptr = pedersen_ptr
        else:
            # user lost - refund their excess bet amount, if any
            _dist_money(market.total_down, market.total_up, bet.amount, user, 0)

            # rebinding ptrs, thus removing binding ambiguity
            tempvar range_check_ptr = range_check_ptr     
            tempvar storage_ptr = storage_ptr  
            tempvar pedersen_ptr = pedersen_ptr
        end
    else:
        # rebinding ptrs, thus removing binding ambiguity
        tempvar range_check_ptr = range_check_ptr     
        tempvar storage_ptr = storage_ptr  
        tempvar pedersen_ptr = pedersen_ptr
    end

    if market.ruling == 1: 
        if bet.direction == 1:
            # user won - return their bet amount & winning share
            _dist_money(market.total_up, market.total_down, bet.amount, user, 1)

            # rebinding ptrs, thus removing binding ambiguity
            tempvar range_check_ptr = range_check_ptr     
            tempvar storage_ptr = storage_ptr  
            tempvar pedersen_ptr = pedersen_ptr
        else:
            # user lost - refund their excess bet amount, if any
            _dist_money(market.total_up, market.total_down, bet.amount, user, 0)

            # rebinding ptrs, thus removing binding ambiguity
            tempvar range_check_ptr = range_check_ptr     
            tempvar storage_ptr = storage_ptr  
            tempvar pedersen_ptr = pedersen_ptr
        end
    else:
        # rebinding ptrs, thus removing binding ambiguity
        tempvar range_check_ptr = range_check_ptr     
        tempvar storage_ptr = storage_ptr  
        tempvar pedersen_ptr = pedersen_ptr
    end

    # nullify user's bet
    local new_bet: Bet = Bet(market_id=0, user=0, amount=0, direction=0)
    bets.write(bet.market_id, user, new_bet)

    _claim_rewards(market_ids_len - 1, market_ids + 1, user)
    return()
end

func _resolve_markets{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(market_ids_len: felt, market_ids: felt*, ruling_list_len: felt, ruling_list: felt*) -> ():
    alloc_locals

    if market_ids_len == 0:
        return ()
    end

    assert_nn_le([ruling_list], 2)

    let (market) = markets.read([market_ids])
    assert market.market_id = [market_ids] # checking because market could be non existant as well
    assert market.state = 2 # market is in state of resolving
    tempvar updated_market: Market = Market(market_id = market.market_id, market_identifier = market.market_identifier,timestamp = market.timestamp, state = 3, total_vol = market.total_vol, total_up = market.total_up, total_down = market.total_down, ruling = [ruling_list])
    markets.write([market_ids], updated_market) 

   _resolve_markets(market_ids_len-1, market_ids+1, ruling_list_len-1, ruling_list+1)
   return ()
end

func _change_markets_to_state{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(market_ids_len: felt, market_ids: felt*, state: felt) -> ():
    alloc_locals

    if market_ids_len == 0:
        return ()
    end

    let (local market) = markets.read([market_ids])
    assert market.market_id = [market_ids] # confirms market exists
    assert market.state = 1 # cannot use this function when state is any int other than 1

    assert_nn_le(state, 4) # state is always <= 4
    assert_not_equal(state, 3) # 1 -> 3 not possible
    assert_not_equal(state, 0) # 1 -> 0 not possible
    assert_not_equal(state, 1) # seriously?

    tempvar updated_market: Market = Market(market_id = market.market_id, market_identifier = market.market_identifier,timestamp = market.timestamp, state = state, total_vol = market.total_vol, total_up = market.total_up, total_down = market.total_down, ruling = market.ruling)
    markets.write([market_ids], updated_market)

    _change_markets_to_state(market_ids_len-1, market_ids+1, state)
    return ()
end

func _place_bet{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(user: felt, market_id: felt, bet_amount: felt, bet_direction: felt) -> ():
    alloc_locals
    # market_id = 0 -> not a valid market
    # bet = 0 -> not a valid bet
    assert_not_zero(market_id)
    assert_not_zero(bet_amount)

    # bet should not exist
    let (local check_bet) = bets.read(market_id, user)
    assert check_bet.market_id = 0
    assert check_bet.user = 0

    # user should have enough balance
    let (local user_balance) = balances.read(user)
    assert_le(bet_amount, user_balance)

    # check market exists & update market info
    let (check_market) = markets.read(market_id)
    assert check_market.market_id = market_id # confirms that market exists
    assert check_market.state = 1 # bets can be places & removed when the market is active (i.e. state = 1)
    tempvar updated_market: Market
    assert updated_market.market_id = check_market.market_id
    assert updated_market.market_identifier = check_market.market_identifier
    assert updated_market.timestamp = check_market.timestamp
    assert updated_market.state = check_market.state
    assert updated_market.total_vol = check_market.total_vol + bet_amount
    assert updated_market.ruling = check_market.ruling
    if bet_direction == 0:
        assert updated_market.total_down = check_market.total_down + bet_amount
        assert updated_market.total_up = check_market.total_up
    else:
        assert updated_market.total_down = check_market.total_down
        assert updated_market.total_up = check_market.total_up + bet_amount
    end
    markets.write(market_id, updated_market)

    # update user's balance
    tempvar new_balance = user_balance - bet_amount 
    balances.write(user, new_balance)
    
    # place user's bet
    tempvar new_bet: Bet = Bet(market_id = market_id, user = user, amount = bet_amount, bet_direction = bet_direction)
    bets.write(market_id, user, new_bet)

    return ()
end

func _remove_bet{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(user: felt, market_id: felt) -> ():
    alloc_locals

    # check bet's existence
    let (local check_bet) = bets.read(market_id, user)
    assert check_bet.market_id = market_id
    assert check_bet.user = user

    # remove bet
    tempvar updated_bet: Bet = Bet(market_id = 0, user = 0, amount = 0, direction = 0)
    bets.write(market_id, user, updated_bet)

    # update user's balance
    let (user_balance) = balances.read(user)
    balances.write(user, user_balance + check_bet.amount)

    # update market
    let (market) = markets.read(market_id)
    assert market.state = 1 # bets can be places & removed when the market is active (i.e. state = 1)
    tempvar updated_market: Market
    assert updated_market.market_id = market.market_id
    assert updated_market.market_identifier = market.market_identifier
    assert updated_market.timestamp = market.timestamp
    assert updated_market.state = market.state
    assert updated_market.total_vol = market.total_vol - check_bet.amount
    assert updated_market.ruling = market.ruling
    if check_bet.direction == 0:
        assert updated_market.total_down = market.total_down - check_bet.amount
        assert updated_market.total_up = market.total_up
    else:
        assert updated_market.total_down = market.total_down
        assert updated_market.total_up = market.total_up - check_bet.amount
    end
    markets.write(market_id, updated_market)

    return ()
end

@l1_handler
func deposit{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }(from_address : felt, user : felt, amount : felt):
    # commenting out for testing
    # Make sure the message was sent by the intended L1 contract.
    let (l1_address) = _l1_contract.read()
    assert from_address = l1_address

    let (res) = balances.read(user=user)
    # Compute and update the new balance.
    tempvar new_balance = res + amount
    balances.write(user, new_balance)
    return ()
end

####################
# EXTERNAL FUNCTIONS
####################

@external
func add_market{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr}(market_identifier: felt) -> (market_id: felt):
    alloc_locals
    
    # check initialized
    let (_initialized) = initialized.read()
    assert _initialized = 1

    # create new market
    let (current_market_index) = market_index.read()
    local new_market: Market = Market(market_id = current_market_index + 1, market_identifier = market_identifier, timestamp = 0, state = 1, totalVol = 0, totalDown = 0, totalUp = 0, ruling = 2)
    markets.write(current_market_index + 1, new_market)
    market_index.write(current_market_index + 1)
    return (market_id=new_market.market_id)
end

@external
func place_bet{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(user: felt, market_id: felt, bet_amount: felt, bet_direction: felt, sig_r: felt, sig_s: felt) -> ():
    
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}(market_id, bet_amount)
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}(arg_hash, bet_direction)
    verify_ecdsa_signature(
        message=arg_hash,
        public_key=user,
        signature_r=sig_r,
        signature_s=sig_s)
    tempvar mul_bet_amount = bet_amount * AMOUNT_MUL
    _place_bet(user, market_id, mul_bet_amount, bet_direction)
    return ()
end

@external
func remove_bet{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(user: felt, market_id: felt, sig_r: felt, sig_s: felt) -> ():
    alloc_locals

    # verify signature
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}(market_id, 0)
    verify_ecdsa_signature(
        message=arg_hash,
        public_key=user,
        signature_r=sig_r,
        signature_s=sig_s)

    _remove_bet(user, market_id)
    return ()
end

@external 
func change_market_to_resolving{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(market_id: felt , sig_r: felt, sig_s: felt) -> ():
    alloc_locals
    # verify owner's signature 
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}(market_id, 0)
    let (owner) = _owner.read()
    verify_ecdsa_signature(
        message=arg_hash,
        public_key=owner,
        signature_r=sig_r,
        signature_s=sig_s 
    )

    let fp_and_pc = get_fp_and_pc()
    local __fp__ = fp_and_pc.fp_val
    _change_markets_to_state(1, &market_id, 2)
    return ()
end

@external 
func change_markets_to_resolving{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(market_ids_len: felt, market_ids: felt* , sig_r: felt, sig_s: felt) -> ():
    # verify owner's signature 
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}([market_ids], market_ids_len)
    let (owner) = _owner.read()
    verify_ecdsa_signature(
        message=arg_hash,
        public_key=owner,
        signature_r=sig_r,
        signature_s=sig_s 
    )
    _change_markets_to_state(market_ids_len, market_ids, 2)
    return ()
end

@external 
func change_market_to_expired{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(market_id: felt, sig_r: felt, sig_s: felt) -> ():
    alloc_locals

    # verify owner's signature 
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}(market_id, 0)
    let (owner) = _owner.read()
    verify_ecdsa_signature(
        message=arg_hash,
        public_key=owner,
        signature_r=sig_r,
        signature_s=sig_s 
    )

    let fp_and_pc = get_fp_and_pc()
    local __fp__ = fp_and_pc.fp_val
    _change_markets_to_state(1, &market_id, 4)
    return ()
end

@external 
func change_markets_to_expired{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(market_ids_len: felt, market_ids: felt*, sig_r: felt, sig_s: felt) -> ():
    # verify owner's signature 
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}([market_ids], market_ids_len)
    let (owner) = _owner.read()
    verify_ecdsa_signature(
        message=arg_hash,
        public_key=owner,
        signature_r=sig_r,
        signature_s=sig_s 
    )
    _change_markets_to_state(market_ids_len, market_ids, 4)
    return ()
end

@external
func resolve_market{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(market_id: felt, ruling: felt, sig_r:felt, sig_s: felt) -> ():
    alloc_locals
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}(market_id, ruling)
    let (owner) = _owner.read()
    verify_ecdsa_signature(
        message=arg_hash,
        public_key=owner,
        signature_r=sig_r,
        signature_s=sig_s 
    )

    let fp_and_pc = get_fp_and_pc()
    local __fp__ = fp_and_pc.fp_val
    _resolve_markets(1, &market_id, 1, &ruling)
    return ()
end

@external
func resolve_markets{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(market_ids_len: felt, market_ids: felt*, ruling_list_len: felt, ruling_list: felt*,sig_r:felt, sig_s: felt) -> ():
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}([market_ids], market_ids_len)
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}(arg_hash, [ruling_list])
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}(arg_hash, ruling_list_len)
    let (owner) = _owner.read()
    verify_ecdsa_signature(
        message=arg_hash,
        public_key=owner,
        signature_r=sig_r,
        signature_s=sig_s 
    )
    _resolve_markets(market_ids_len, market_ids, ruling_list_len, ruling_list)
    return ()
end

@external
func claim_rewards{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*
    }(market_ids_len: felt, market_ids: felt*, user: felt) -> ():
    _claim_rewards(market_ids_len, market_ids, user)
    return()
end

@external
func refund_bet{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr}(market_id: felt, user:felt) -> ():
    let (market) = markets.read(market_id)
    assert market.market_id = market_id # confirms that market exists
    assert market.state = 4 # refund only possible in state 4 (expired state)
    
    let (bet) = bets.read(market_id, user)
    assert bet.market_id = market_id
    assert bet.user = user

    # refund user bet amount
    let (user_balance) = balances.read(user)
    balances.write(user, user_balance + bet.amount)

    # nullify user's bet
    tempvar new_bet: Bet = Bet(market_id=0, user=0, amount=0, direction=0)
    bets.write(bet.market_id, user, new_bet)
    
    return ()
end

@external
func modify_l1_contract_address{
    storage_ptr : Storage*, 
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(new_address: felt, sig_r: felt, sig_s: felt) -> ():
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}(new_address, 0)
    let (owner) = _owner.read()
    verify_ecdsa_signature(
        message=arg_hash,
        public_key=owner,
        signature_r=sig_r,
        signature_s=sig_s 
    )
    _l1_contract.write(new_address)
    return ()
end

@external
func modify_owner{
    storage_ptr: Storage*, 
    pedersen_ptr: HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr : SignatureBuiltin*}(new_owner: felt, sig_r: felt, sig_s: felt) -> ():
    let (arg_hash) = hash2{hash_ptr=pedersen_ptr}(new_owner, 0)
    let (owner) = _owner.read()
    verify_ecdsa_signature(
        message=arg_hash,
        public_key=owner,
        signature_r=sig_r,
        signature_s=sig_s 
    )
    _owner.write(new_owner)
    return ()
end

@external
func initialize{
    storage_ptr: Storage*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
    } (owner: felt, l1_contract: felt):
    let (_initialized) = initialized.read()
    assert _initialized = 0
    initialized.write(1)
    _owner.write(owner)
    _l1_contract.write(l1_contract)
    return ()
end


####################
# VIEW FUNCTIONS
####################

@view
func view_balance{
    storage_ptr : Storage*, 
    range_check_ptr,
    pedersen_ptr : HashBuiltin*}(user: felt) -> (user:felt, balance: felt):
    let (balance) = balances.read(user)
    return (user=user, balance=balance)
end

@view 
func view_market{
    storage_ptr : Storage*, 
    range_check_ptr,
    pedersen_ptr : HashBuiltin*}(market_id: felt) -> (market_id: felt, market_identifier: felt, timestamp: felt, state: felt, total_vol: felt, total_up: felt, total_down: felt, ruling: felt):
    let (data) = markets.read(market_id)
    return (market_id=data.market_id, market_identifier=data.market_identifier, timestamp=data.timestamp, state=data.state, total_vol=data.total_vol, total_up=data.total_up, total_down=data.total_down, ruling=data.ruling)
end

@view
func view_bet{
    storage_ptr : Storage*,
    range_check_ptr, 
    pedersen_ptr : HashBuiltin*}(market_id: felt, user: felt) -> (market_id: felt, user: felt, amount: felt, direction: felt):
    let (bet) = bets.read(market_id, user)
    return (market_id=bet.market_id, user=bet.user, amount=bet.amount, direction=bet.direction)
end

@view
func view_owner{
    storage_ptr : Storage*, 
    range_check_ptr,
    pedersen_ptr : HashBuiltin*}() -> (owner: felt):
    let (owner) = _owner.read()
    return (owner=owner)
end

@view
func view_l1_contract{
    storage_ptr : Storage*, 
    range_check_ptr,
    pedersen_ptr : HashBuiltin*}() -> (l1_contract: felt):
    let (l1_contract) = _l1_contract.read()
    return (l1_contract=l1_contract)
end
