-- =====================================================================
-- TIMBRATURE HOTEL ROSANNA – schema database Supabase
-- ---------------------------------------------------------------------
-- Da incollare UNA VOLTA nel SQL Editor del progetto Supabase di
-- Hotel Rosanna (Dashboard -> SQL Editor -> New query -> Run).
--
-- Sicurezza:
--  * La pagina web è pubblica (GitHub Pages) e la chiave "publishable"
--    è visibile a chiunque: è normale. A proteggere i dati sono le
--    regole RLS qui sotto.
--  * Chi NON ha fatto login (il kiosk) non può leggere né modificare
--    nessuna tabella. Può solo chiamare la funzione timbra(), e solo
--    se conosce il codice segreto del kiosk.
--  * Chi fa login vede i dati SOLO se è nella tabella "amministratori".
--    Anche se qualcuno si registrasse da solo, non vedrebbe nulla.
-- =====================================================================

-- ---------- TABELLE ----------

create table public.dipendenti (
  id      uuid primary key default gen_random_uuid(),
  nome    text not null,
  reparto text,
  badge   text not null unique,          -- codice letto dal lettore RFID
  attivo  boolean not null default true,
  creato  timestamptz not null default now()
);

create table public.timbrature (
  id     uuid primary key default gen_random_uuid(),
  dip_id uuid not null references public.dipendenti(id) on delete restrict,
  ts     timestamptz not null,             -- orario REALE della timbratura
  tipo   char(1) not null check (tipo in ('E', 'U')),   -- E = entrata, U = uscita
  fonte  text not null default 'badge' check (fonte in ('badge', 'manuale', 'offline')),
  nota   text,
  creato timestamptz not null default now()
);
create index timbrature_dip_ts on public.timbrature (dip_id, ts desc);
create index timbrature_ts on public.timbrature (ts);

-- Badge passati al kiosk ma non associati a nessun dipendente
create table public.badge_sconosciuti (
  id     uuid primary key default gen_random_uuid(),
  codice text not null,
  ts     timestamptz not null default now()
);

-- Registro di ogni modifica fatta dal pannello (chi, cosa, quando)
create table public.registro (
  id        uuid primary key default gen_random_uuid(),
  ts        timestamptz not null default now(),
  azione    text not null,
  dettaglio text,
  utente    uuid default auth.uid()
);

-- Impostazioni: una sola riga (regole pausa, arrotondamento, codice kiosk)
create table public.impostazioni (
  id          int primary key default 1 check (id = 1),
  valori      jsonb not null default '{}'::jsonb,
  kiosk_token text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);
insert into public.impostazioni (id) values (1);

-- Utenti che possono usare il pannello di amministrazione
create table public.amministratori (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email   text
);

-- ---------- CONTROLLO AMMINISTRATORE ----------

create function public.is_admin() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.amministratori where user_id = (select auth.uid()));
$$;

-- ---------- RLS: tutto chiuso, solo amministratori ----------

alter table public.dipendenti        enable row level security;
alter table public.timbrature        enable row level security;
alter table public.badge_sconosciuti enable row level security;
alter table public.registro          enable row level security;
alter table public.impostazioni      enable row level security;
alter table public.amministratori    enable row level security;

create policy admin_tutto on public.dipendenti        for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_tutto on public.timbrature        for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_tutto on public.badge_sconosciuti for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_tutto on public.impostazioni      for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
-- Il registro si può leggere e aggiungere, ma non modificare o cancellare
create policy admin_legge    on public.registro for select to authenticated using ((select public.is_admin()));
create policy admin_aggiunge on public.registro for insert to authenticated with check ((select public.is_admin()));
-- Ognuno vede solo la propria riga (serve all'app per sapere se è admin)
create policy vede_se_stesso on public.amministratori for select to authenticated using (user_id = (select auth.uid()));

-- Permessi espliciti per gli utenti loggati (le regole RLS sopra filtrano chi è admin)
grant select, insert, update, delete on public.dipendenti, public.timbrature,
      public.badge_sconosciuti, public.impostazioni to authenticated;
grant select, insert on public.registro to authenticated;
grant select on public.amministratori to authenticated;

-- Chi non ha fatto login non ha nessun accesso diretto alle tabelle
revoke all on public.dipendenti, public.timbrature, public.badge_sconosciuti,
              public.registro, public.impostazioni, public.amministratori from anon;

-- ---------- FUNZIONE DEL KIOSK: timbra() ----------
-- Riceve il codice segreto del kiosk e il codice badge.
-- Decide da sola se è ENTRATA o USCITA, ignora i doppi passaggi
-- e registra i badge sconosciuti. p_ts serve solo per le timbrature
-- fatte senza connessione e inviate dopo (massimo 3 giorni prima).

create function public.timbra(p_token text, p_codice text, p_ts timestamptz default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_imp        public.impostazioni%rowtype;
  v_dip        public.dipendenti%rowtype;
  v_ultima     public.timbrature%rowtype;
  v_ts         timestamptz;
  v_tipo       char(1);
  v_antidoppio int;
  v_turnomax   numeric;
  v_codice     text := upper(regexp_replace(coalesce(p_codice, ''), '\s', '', 'g'));
begin
  select * into v_imp from public.impostazioni where id = 1;
  if not found or p_token is null or p_token <> v_imp.kiosk_token then
    return jsonb_build_object('esito', 'non_autorizzato');
  end if;
  if length(v_codice) < 3 or length(v_codice) > 64 then
    return jsonb_build_object('esito', 'codice_non_valido');
  end if;

  v_ts := coalesce(p_ts, now());
  if v_ts > now() + interval '5 minutes' or v_ts < now() - interval '3 days' then
    v_ts := now();
  end if;

  select * into v_dip from public.dipendenti where badge = v_codice and attivo;
  if not found then
    insert into public.badge_sconosciuti (codice, ts) values (v_codice, v_ts);
    return jsonb_build_object('esito', 'sconosciuto');
  end if;

  v_antidoppio := coalesce((v_imp.valori ->> 'antiDoppioSec')::int, 60);
  v_turnomax   := coalesce((v_imp.valori ->> 'turnoMassimoOre')::numeric, 16);

  select * into v_ultima from public.timbrature
   where dip_id = v_dip.id and ts <= v_ts order by ts desc limit 1;

  -- Doppio passaggio ravvicinato: non registra nulla
  if found and v_ts - v_ultima.ts < make_interval(secs => v_antidoppio) then
    return jsonb_build_object('esito', 'doppio', 'nome', v_dip.nome, 'tipo', v_ultima.tipo, 'ts', v_ultima.ts);
  end if;

  -- Ultima = entrata recente -> ora è un'uscita, altrimenti entrata
  if found and v_ultima.tipo = 'E' and v_ts - v_ultima.ts < make_interval(secs => (v_turnomax * 3600)::int) then
    v_tipo := 'U';
  else
    v_tipo := 'E';
  end if;

  insert into public.timbrature (dip_id, ts, tipo, fonte)
  values (v_dip.id, v_ts, v_tipo, case when p_ts is null then 'badge' else 'offline' end);

  return jsonb_build_object('esito', 'ok', 'nome', v_dip.nome, 'tipo', v_tipo, 'ts', v_ts,
                            'entrata', case when v_tipo = 'U' then v_ultima.ts end);
end;
$$;

-- Quante persone sono in servizio adesso (per il piede del kiosk)
create function public.in_servizio(p_token text) returns int
language sql stable security definer set search_path = ''
as $$
  select case when p_token = (select kiosk_token from public.impostazioni where id = 1) then (
    select count(*)::int from (
      select distinct on (dip_id) tipo, ts from public.timbrature
       where ts > now() - interval '16 hours'
       order by dip_id, ts desc) u
     where u.tipo = 'E')
  else null end;
$$;

revoke all on function public.timbra(text, text, timestamptz) from public;
revoke all on function public.in_servizio(text) from public;
revoke all on function public.is_admin() from public;
grant execute on function public.timbra(text, text, timestamptz) to anon, authenticated;
grant execute on function public.in_servizio(text) to anon, authenticated;
grant execute on function public.is_admin() to authenticated;
