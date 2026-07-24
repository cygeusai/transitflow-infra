# Security Policy

## Reporting
Report suspected vulnerabilities privately to the Transit & Flow owner. Do not open
a public issue for security matters.

## Principles
- Access control is enforced in the database via Row-Level Security, not the UI.
- Secrets live in Supabase Vault and are referenced by name; never commit secrets.
- SECURITY DEFINER functions revoke `public, anon` and grant least privilege.
- Money movement (payments) and outbound customer messaging are gated behind
  explicit configuration flags and require owner sign-off to enable.

## Rotations
Rotate any credential that is ever shared outside the Vault (for example, pasted in
chat or a ticket) as soon as it is no longer needed.
