# Database Setup

This app stores its data in [Supabase](https://supabase.com) (a hosted Postgres database).
The repo contains the database **structure** in `schema.sql`. It contains no member data and no secrets.

You have two options.

## Option A: Use your own copy (recommended for testing)

1. Create a free account at supabase.com and click **New project**.
2. Open **SQL Editor -> New query**, paste the whole contents of `schema.sql`, and click **Run**.
3. Open **Project Settings -> API** and copy:
   - **Project URL**
   - **Publishable (anon) key**
4. In `index.html`, find these two lines (around line 6523) and replace the values with yours:
   ```js
   var SUPABASE_URL      = 'https://YOUR-PROJECT-ID.supabase.co';
   var SUPABASE_ANON_KEY = 'YOUR-PUBLISHABLE-KEY';
   ```
5. Open **Authentication -> Users -> Add user** and create your admin login (email and password).
6. Open **Authentication -> Sign In / Providers** and turn **off** "Allow new users to sign up".
   Every logged-in user is treated as an admin, so sign-ups must stay closed.
7. Open `index.html` in your browser and sign in with the admin account.

## Option B: Use the owner's live database

No setup is needed. Ask the project owner to:
- Invite you to the Supabase organization (**Organization -> Team**), and/or
- Create an admin login for you (**Authentication -> Users**).

## Important

- **Never commit** your `service_role` key, your database password, or your Gemini API key to this repo.
  Only the publishable key is safe to appear in `index.html`.
- The Gemini API key is entered in the app under **Settings** after you log in. It is stored in the
  database and is blocked from anonymous reads by the policy in `schema.sql`.
- Do not commit real member data (names and phone numbers) to this repo.
