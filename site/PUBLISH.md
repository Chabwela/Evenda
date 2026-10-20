# Publishing Evenda's public pages (GitHub Pages)

Google Play needs two public links: the privacy policy and the account-deletion
page. This folder is the whole site.

1. Make sure no `[CONFIRM]` items are left in `privacy-policy.html` and
   `delete-account.html`.
2. On github.com, create a **public** repository named `evenda`.
3. In the repository: **Add file → Upload files**, drag in `index.html`,
   `privacy-policy.html`, `delete-account.html` and `.nojekyll` (not this file),
   then **Commit changes**.
4. **Settings → Pages → Build and deployment**: Source "Deploy from a branch",
   Branch `main`, folder `/ (root)`, **Save**. After a minute or two the site is
   live at `https://<your-username>.github.io/evenda/`.
5. Open both pages on your phone to check them.
6. Put the links in `env/prod.json`:
   - `PRIVACY_POLICY_URL`: `https://<your-username>.github.io/evenda/privacy-policy.html`
   - `ACCOUNT_DELETION_URL`: `https://<your-username>.github.io/evenda/delete-account.html`
7. Use the same two links in Play Console (App content → Privacy policy, and
   Data safety → Data deletion).

When a policy changes, upload the new file to the same repository; the links
stay the same.
