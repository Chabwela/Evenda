# Evenda auth email templates

Paste each file into Supabase Dashboard -> Authentication -> Emails -> Templates
(editable once custom SMTP is set). The app expects a 6-digit code ({{ .Token }}),
not a link, so keep the code block in every template.

| Template        | Subject                               | File                |
|-----------------|---------------------------------------|---------------------|
| Confirm signup  | Your Evenda code: {{ .Token }}        | confirm_signup.html |
| Reset password  | Reset your Evenda password            | reset_password.html |
| Change email    | Confirm your new Evenda email         | email_change.html   |

Also set Authentication -> Providers -> Email -> "Email OTP Length" to 6.
