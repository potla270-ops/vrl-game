-- VRL atomic batch betting
-- Applied to VRL-Testing project yjdkjidcjafshwsaiado.
-- The Edge Function calls this with the authenticated user ID after session/device checks.

create table if not exists public.bet_submissions (
  user_id uuid not null references public.profiles(id) on delete restrict,
  submission_id uuid not null,
  round_id bigint not null references public.rounds(id) on delete restrict,
  request_hash text not null check (length(request_hash)=64),
  response jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (user_id, submission_id)
);
create index if not exists bet_submissions_round_id_idx on public.bet_submissions(round_id);
alter table public.bet_submissions enable row level security;
revoke all on public.bet_submissions from public, anon, authenticated;
grant select, insert on public.bet_submissions to service_role;

create or replace function public.vrl_place_bet_batch(
  p_user_id uuid, p_round_id bigint, p_submission_id uuid, p_bets jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $function$
declare
  v_existing public.bet_submissions%rowtype;
  v_round public.rounds%rowtype;
  v_wallet public.wallets%rowtype;
  v_item jsonb;
  v_number integer;
  v_stake bigint;
  v_total bigint := 0;
  v_balance numeric;
  v_hash text;
  v_rows jsonb := '[]'::jsonb;
  v_bet_id uuid;
  v_key uuid;
  v_response jsonb;
  v_count integer;
  v_distinct_count integer;
begin
  if p_user_id is null or p_round_id is null or p_round_id <= 0 or p_submission_id is null
     or p_bets is null or jsonb_typeof(p_bets) <> 'array'
     or jsonb_array_length(p_bets) < 1 or jsonb_array_length(p_bets) > 12 then
    raise exception 'Invalid batch bet details';
  end if;
  if not exists (select 1 from public.profiles p where p.id=p_user_id and p.role='player' and p.status='active') then
    raise exception 'Active Player account required';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_bets) x
    where jsonb_typeof(x) <> 'object' or not (x ? 'number') or not (x ? 'stake')
       or (x->>'number') !~ '^[0-9]+$' or (x->>'stake') !~ '^[0-9]+$'
       or (x->>'number')::integer not between 1 and 12
       or (x->>'stake')::numeric <= 0 or (x->>'stake')::numeric > 9007199254740991
  ) then raise exception 'Invalid bet selection'; end if;

  select count(*),count(distinct (x->>'number')::integer),coalesce(sum((x->>'stake')::numeric),0)
    into v_count,v_distinct_count,v_total from jsonb_array_elements(p_bets) x;
  if v_count <> v_distinct_count or v_total <= 0 or v_total > 9007199254740991 then
    raise exception 'Duplicate numbers or invalid total stake';
  end if;

  v_hash := encode(extensions.digest(convert_to(
    jsonb_build_object('round_id',p_round_id,'bets',(
      select jsonb_agg(jsonb_build_object('number',(x->>'number')::integer,'stake',(x->>'stake')::bigint)
                       order by (x->>'number')::integer)
      from jsonb_array_elements(p_bets) x
    ))::text,'UTF8'),'sha256'),'hex');

  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text||':'||p_submission_id::text,0));
  select * into v_existing from public.bet_submissions
   where user_id=p_user_id and submission_id=p_submission_id;
  if found then
    if v_existing.request_hash <> v_hash then raise exception 'Submission ID was already used with a different ticket'; end if;
    return v_existing.response || jsonb_build_object('duplicate',true);
  end if;

  select * into v_round from public.rounds where id=p_round_id for update;
  if not found or v_round.status <> 'betting' or clock_timestamp() >= v_round.betting_ends_at then
    raise exception 'Betting is closed';
  end if;
  if exists (select 1 from public.app_config c where c.id=true and c.emergency_stop) then
    raise exception 'Game is temporarily paused';
  end if;

  select * into v_wallet from public.wallets where user_id=p_user_id for update;
  if not found or v_wallet.balance < v_total then raise exception 'Insufficient balance'; end if;

  v_balance := v_wallet.balance;
  for v_item in select x from jsonb_array_elements(p_bets) x order by (x->>'number')::integer loop
    v_number := (v_item->>'number')::integer;
    v_stake := (v_item->>'stake')::bigint;
    v_balance := v_balance-v_stake;
    v_bet_id := gen_random_uuid();
    v_key := gen_random_uuid();
    insert into public.bets(id,round_id,user_id,number,stake,idempotency_key)
      values(v_bet_id,p_round_id,p_user_id,v_number,v_stake,v_key);
    insert into public.wallet_ledger(
      user_id,kind,amount_delta,balance_after,reference_type,reference_id,idempotency_key,actor_id,note
    ) values (
      p_user_id,'bet_debit',-v_stake,v_balance,'bet',v_bet_id::text,v_key,p_user_id,
      'Round bet (batch submission '||p_submission_id::text||')'
    );
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'bet_id',v_bet_id,'round_id',p_round_id,'number',v_number,'stake',v_stake
    ));
  end loop;

  update public.wallets set balance=v_balance,updated_at=clock_timestamp() where user_id=p_user_id;
  update public.rounds set total_bets=total_bets+v_total where id=p_round_id;

  v_response := jsonb_build_object('submission_id',p_submission_id,'round_id',p_round_id,
    'bets',v_rows,'total_stake',v_total,'balance',v_balance,'duplicate',false);
  insert into public.bet_submissions(user_id,submission_id,round_id,request_hash,response)
    values(p_user_id,p_submission_id,v_round.id,v_hash,v_response);
  return v_response;
end;
$function$;

revoke all on function public.vrl_place_bet_batch(uuid,bigint,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.vrl_place_bet_batch(uuid,bigint,uuid,jsonb) to service_role;
