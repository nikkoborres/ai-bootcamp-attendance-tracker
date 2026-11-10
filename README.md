# AI Bootcamp Attendance Tracker

A simple attendance tracker for groups and events, built as a **single HTML file** with a
[Supabase](https://supabase.com) database behind it.

Admins manage members and groups and mark weekly attendance. Participants can register and check in
by scanning a QR code, without needing an account.

## Features

- **Admin dashboard:** secure login, members, groups, and weekly attendance marking
- **History and stats:** attendance history, attendance rates, and CSV export
- **Bulk import:** add many members at once from a CSV file
- **QR check-in:** participants check in by scanning their QR code (member number or name)
- **Self-registration:** a public page where new participants register and receive their QR code
- **Custom branding:** upload and switch logos, and set the tracker name and event dates
- **Light and dark theme**
- **Optional AI assistant:** ask questions about attendance, powered by Google Gemini (admin adds their own API key in Settings)

## Tech stack

- HTML, CSS, and vanilla JavaScript (everything is in `index.html`)
- [Supabase](https://supabase.com) for the Postgres database, authentication, and logo storage

## Getting started

1. Clone the repo:
   ```bash
   git clone https://github.com/nikkoborres/ai-bootcamp-attendance-tracker.git
   ```
2. Set up the database by following **[DATABASE_SETUP.md](DATABASE_SETUP.md)**. It uses `schema.sql`, which creates all tables, security rules, and functions.
3. Put your own Supabase URL and publishable key in `index.html` (the guide shows where).
4. Open `index.html` in your browser and sign in with the admin account you created.

## Project files

| File | What it is |
| --- | --- |
| `index.html` | The whole app |
| `schema.sql` | Database structure (no data, no secrets) |
| `DATABASE_SETUP.md` | Step-by-step database setup |
| `LICENSE` | MIT License |

## Security notes

- The key in `index.html` is Supabase's **publishable** key, which is designed to be public. Your data is protected by the Row Level Security rules in `schema.sql`.
- Keep sign-ups **disabled** in Supabase Authentication, because every logged-in user is treated as an admin.
- Never commit your `service_role` key, database password, or Gemini API key.
- Don't commit real member data (names and phone numbers).

## License

[MIT](LICENSE)
