# Evenda — closed test plan (personal Play account)

Google requires a **new personal developer account** to run a **closed test with
≥ 12 testers, opted in for 14 continuous days**, before you can apply for
production access. This is a hard gate; plan for ~2.5 weeks from first upload to
production.

## Order of operations
1. **Create the app** in Play Console. Complete App content + Store listing
   (text in `STORE_LISTING.md`, data safety in `DATA_SAFETY.md`, the 6
   screenshots in `screenshots/`).
2. **Internal testing** (just you): upload the `.aab`, install from the opt-in
   link, confirm sign-in, maps, push and a booking work on a real phone.
3. **Closed testing**: create a track (e.g. "Closed test"), add ≥ 12 testers
   (see below), publish. Send each tester the opt-in link.
4. **Keep them opted in 14 days.** The 12 must remain testers for 14 continuous
   days. If someone opts out, the clock can reset — recruit a couple of spares
   (aim for 14–15).
5. **Apply for production** once Play shows the requirement met (Dashboard shows
   progress). Then promote the build to Production.

## The 12 testers
- Each tester needs a **Google account** (their Gmail) added to the test — by
  email list or a Google Group (a group is easier: add one group, people join it).
- They must **accept the opt-in link once** and ideally install the app. Real
  installs count best; they don't have to use it daily, but a few opening it
  helps show genuine testing.
- Realistic sources: your team, family, fellow vendors, friends with Android
  phones. 12 distinct Google accounts on Android.
- Create a Google Group (groups.google.com), e.g. `evenda-testers@googlegroups.com`,
  add it as the tester list in Play, and have people join the group.

## Message to send testers (WhatsApp / SMS)
> Hi — I'm launching *Evenda*, an app for event vendors in Zambia (find stock,
> quote, book, Evenda Now for urgent sourcing). I need 12 people to test it on
> Android for 2 weeks before it goes public. It's free and takes 5 minutes:
>
> 1. Send me the Gmail address on your phone.
> 2. I'll send you a link — tap it, tap **Become a tester**, then **Download on
>    Google Play**.
> 3. Open the app once, sign up with your email, and have a look around.
>
> That's it. You can keep or remove it after. Thank you!

## Email version (for a Google Group invite)
> Subject: Help test Evenda before launch (Android, 2 weeks)
>
> Thanks for helping test Evenda. Two quick steps:
> 1. Join the testers group: <group join link>
> 2. Open the test link on your Android phone: <Play opt-in link>, tap
>    "Become a tester", then install from Google Play.
> Sign up with your email and explore. Please keep it installed for ~2 weeks.
> Questions: <your support email>.

## Notes
- The opt-in link and the group link come **from Play Console** after you create
  the closed track — paste them into the messages above.
- Testing can run on the same `.aab` the whole time; you can push updated builds
  to the closed track without resetting the 14 days.
- Keep a simple list of who opted in so you can confirm you have 12 active.
