# Timbrature – Hotel Rosanna

Webapp per la rilevazione presenze con badge RFID (le tessere delle camere).

- `index.html`: la webapp (kiosk + pannello), pubblicata su GitHub Pages
- `supabase/schema.sql`: database e regole di sicurezza (Supabase di Hotel Rosanna)

## Configurazione Supabase (una volta sola)

1. Su [supabase.com](https://supabase.com), con l'account **Hotel Rosanna**, crea un nuovo progetto
   (regione consigliata: *Central EU – Frankfurt*).
2. **SQL Editor → New query**: incolla tutto `supabase/schema.sql` e premi **Run**.
3. **Authentication → Users → Add user → Create new user**: inserisci la tua email e una password,
   spunta *Auto Confirm User*.
4. Di nuovo nel **SQL Editor**, abilita il tuo utente al pannello (metti la tua email):
   ```sql
   insert into public.amministratori (user_id, email)
   select id, email from auth.users where email = 'LA-TUA-EMAIL';
   ```
5. **Authentication → Sign In / Providers**: disattiva *Allow new users to sign up*
   (così nessuno può creare account da solo).
6. **Project Settings → API Keys**: copia *Project URL* e la chiave **publishable** (`sb_publishable_…`)
   e mettile in cima allo script di `index.html` (`SUPABASE_URL`, `SUPABASE_KEY`).
   ⚠️ Non usare MAI la chiave *secret* / *service_role* nella pagina.

## Primo avvio del tablet

1. Apri la pagina dal tablet, tocca il lucchetto e accedi.
2. **Impostazioni → Usa questo dispositivo come kiosk**.
3. **Dipendenti → + Nuovo dipendente → Leggi badge dal lettore** per ogni persona.
4. Torna al kiosk: il tablet è pronto.

## Sicurezza in breve

- La pagina e la chiave *publishable* sono pubbliche: è normale. I dati sono protetti dalle regole RLS.
- Senza login non si legge nessun dato. Il kiosk può solo timbrare, e solo con il suo codice segreto.
- Solo gli utenti nella tabella `amministratori` vedono e modificano i dati.
- Tablet perso o rubato: **Impostazioni → Genera un nuovo codice kiosk**.
