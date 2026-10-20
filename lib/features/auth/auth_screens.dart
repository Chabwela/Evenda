import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../app/config.dart';
import '../../core/format.dart';
import '../../core/connectivity.dart';
import '../../core/errors.dart';
import '../../design/ev.dart';
import 'welcome_hero.dart';

/// First frame: the mark draws itself once while the session and business load.
class LaunchScreen extends ConsumerStatefulWidget {
  const LaunchScreen({super.key});

  @override
  ConsumerState<LaunchScreen> createState() => _LaunchScreenState();
}

class _LaunchScreenState extends ConsumerState<LaunchScreen> {
  /// Connected to a network that doesn't reach the internet (e.g. mobile data
  /// with no bundle) never fails fast, so give up waiting after a while.
  static const _patience = Duration(seconds: 10);
  Timer? _timer;
  bool _slow = false;

  Timer? _introTimer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_patience, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Let the mark finish carving before the router moves on (skipped with
    // reduced motion). Only ever once per app start.
    if (_introTimer == null && !ref.read(launchIntroDoneProvider)) {
      _introTimer = Timer(EvMotion.reduced(context) ? Duration.zero : EvendaMark.introDuration + const Duration(milliseconds: 150), () {
        ref.read(launchIntroDoneProvider.notifier).set(true);
        if (mounted) setState(() {});
      });
    }
  }

  // Stay on the offline state while retrying (no flash back to the spinner);
  // the router leaves this screen as soon as the business loads.
  void _retry() => ref.invalidate(myBusinessProvider);

  @override
  void dispose() {
    _timer?.cancel();
    _introTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final biz = ref.watch(myBusinessProvider);
    final err = biz.hasError ? EvError.from(biz.error!) : null;
    // Opened with no connection: Supabase keeps retrying its token refresh
    // instead of failing, so ask the radio directly rather than spin.
    final noNetwork = ref.watch(onlineProvider).value == false && !biz.hasValue;
    final stuck = _slow && biz.isLoading && !biz.hasValue;
    if (noNetwork || stuck || (err != null && (err.isOffline || err.code == 'timeout'))) {
      // The offline state carries its own animated mark; don't stack two logos.
      return Scaffold(
        backgroundColor: EvColors.cream,
        body: SafeArea(child: OfflineState(onRetry: _retry)),
      );
    }
    return Scaffold(
      backgroundColor: EvColors.cream,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const EvendaMark(size: 96, animate: true),
          const SizedBox(height: EvSpace.x6),
          if (biz.hasError)
            ErrorState(error: biz.error!, compact: true, onRetry: _retry)
          else
            // Spinner only once the mark has finished and we're still waiting;
            // reserve its space so the mark never shifts.
            SizedBox(
              height: 20,
              width: 20,
              child: ref.watch(launchIntroDoneProvider) ? const CircularProgressIndicator(strokeWidth: 2) : null,
            ),
        ]),
      ),
    );
  }
}

class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= EvBreakpoints.tablet;
    // Shorter on 360x800-class phones so the story fits above the pinned buttons.
    final heroHeight = (size.height * 0.32).clamp(220.0, 300.0);

    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EvArrive(child: Align(alignment: Alignment.centerLeft, child: EvendaLogo(size: 30))),
      const SizedBox(height: EvSpace.x5),
      EvArrive(delay: const Duration(milliseconds: 120), child: WelcomeHero(height: heroHeight)),
      const SizedBox(height: EvSpace.x6),
      const EvArrive(delay: Duration(milliseconds: 260), child: RotatingPromise()),
      const SizedBox(height: EvSpace.x2),
      EvArrive(
        delay: const Duration(milliseconds: 340),
        child: Text(
          'Evenda connects Lusaka’s event vendors — find stock nearby, quote and book each other, and keep every job on track.',
          style: EvType.body.copyWith(color: EvColors.ink2),
        ),
      ),
    ]);

    // Both ways in stay on screen on every phone height; the story scrolls above them.
    final actions = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EvArrive(
        delay: const Duration(milliseconds: 420),
        child: EvButton('Create a vendor account', icon: LucideIcons.userPlus, expand: true, onPressed: () => context.push('/auth/signup')),
      ),
      const SizedBox(height: EvSpace.x3),
      EvArrive(
        delay: const Duration(milliseconds: 480),
        child: EvButton('I already have an account', kind: EvButtonKind.secondary, icon: LucideIcons.mail, expand: true, onPressed: () => context.push('/auth/email')),
      ),
    ]);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: wide ? 520 : double.infinity),
            child: Column(children: [
              Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x5, EvSpace.gutter, EvSpace.x4), children: [content])),
              Padding(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x4), child: actions),
            ]),
          ),
        ),
      ),
    );
  }
}

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String? _validateEmail(String? v) => (v == null || !_emailPattern.hasMatch(v.trim())) ? 'Enter a valid email' : null;

/// Supabase enforces its own policy too; this catches the common cases early.
String? _validateNewPassword(String? v) {
  if (v == null || v.length < 8) return 'Use at least 8 characters';
  if (!RegExp(r'[A-Za-z]').hasMatch(v) || !RegExp(r'[0-9]').hasMatch(v)) return 'Use both letters and numbers';
  return null;
}

/// Shared frame for the email auth screens: logo, heading, one line of
/// context, then the form straight on the page (no card), like the rest of the app.
class _AuthFrame extends StatelessWidget {
  const _AuthFrame({required this.title, this.intro, required this.child, this.footer});
  final String title;
  final String? intro;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EvColors.cream,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: context.canPop()
            ? IconButton(onPressed: () => context.pop(), icon: const Icon(LucideIcons.arrowLeft, color: EvColors.ink))
            : null,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 8, EvSpace.gutter, EvSpace.x8),
              children: [
                const EvArrive(child: Align(alignment: Alignment.centerLeft, child: EvendaLogo(size: 24))),
                const SizedBox(height: EvSpace.x8),
                EvArrive(
                  delay: const Duration(milliseconds: 80),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: EvType.display),
                    if (intro != null) ...[
                      const SizedBox(height: EvSpace.x2),
                      Text(intro!, style: EvType.body.copyWith(color: EvColors.ink2)),
                    ],
                  ]),
                ),
                const SizedBox(height: EvSpace.x6),
                EvArrive(delay: const Duration(milliseconds: 140), child: child),
                if (footer != null) ...[const SizedBox(height: EvSpace.x6), footer!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PasswordField extends StatefulWidget {
  const _PasswordField({required this.controller, this.label = 'Password', this.isNew = false, this.onSubmitted});
  final TextEditingController controller;
  final String label;
  final bool isNew;
  final VoidCallback? onSubmitted;

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        EvFieldLabel(widget.label),
        TextFormField(
          controller: widget.controller,
          obscureText: _obscure,
          autofillHints: [widget.isNew ? AutofillHints.newPassword : AutofillHints.password],
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: widget.isNew ? _validateNewPassword : (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
          onFieldSubmitted: widget.onSubmitted == null ? null : (_) => widget.onSubmitted!(),
          style: EvType.body,
          decoration: InputDecoration(
            helperText: widget.isNew ? 'At least 8 characters, with letters and numbers' : null,
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show password' : 'Hide password',
              icon: Icon(_obscure ? LucideIcons.eye : LucideIcons.eyeOff, size: 18),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
      ]);
}

class _EmailField extends StatelessWidget {
  const _EmailField({required this.controller, this.autofocus = false});
  final TextEditingController controller;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => EvField(
        label: 'Business email',
        controller: controller,
        autofocus: autofocus,
        keyboardType: TextInputType.emailAddress,
        textCapitalization: TextCapitalization.none,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.email, AutofillHints.username],
        autocorrect: false,
        validator: _validateEmail,
      );
}

class EmailPasswordScreen extends ConsumerStatefulWidget {
  const EmailPasswordScreen({super.key});

  @override
  ConsumerState<EmailPasswordScreen> createState() => _EmailPasswordScreenState();
}

class _EmailPasswordScreenState extends ConsumerState<EmailPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final auth = ref.read(backendProvider).auth;
    try {
      await auth.signIn(_email.text, _password.text);
      // The router moves on once the session and business load.
    } on EvError catch (e) {
      if (!mounted) return;
      if (e.code == 'email_not_confirmed') {
        await guard(context, () => auth.resendEmailCode(_email.text));
        if (mounted) context.push('/auth/code?purpose=signup&email=${Uri.encodeComponent(_email.text.trim())}');
      } else {
        showError(context, e);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AuthFrame(
      title: 'Welcome back',
      intro: 'Sign in to your business on Evenda.',
      footer: Center(
        child: TextButton(onPressed: () => context.pushReplacement('/auth/signup'), child: const Text('New to Evenda? Create an account')),
      ),
      child: AutofillGroup(
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _EmailField(controller: _email),
            const SizedBox(height: EvSpace.x4),
            _PasswordField(controller: _password, onSubmitted: _signIn),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => context.push('/auth/forgot?email=${Uri.encodeComponent(_email.text.trim())}'),
                child: const Text('Forgot password?'),
              ),
            ),
            const SizedBox(height: EvSpace.x2),
            EvButton('Sign in', expand: true, loading: _busy, onPressed: _signIn),
          ]),
        ),
      ),
    );
  }
}

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final needsCode = await guard(context, () => ref.read(backendProvider).auth.signUp(_email.text, _password.text, _name.text));
    if (!mounted) return;
    setState(() => _busy = false);
    // needsCode == false means the project does not require confirmation and
    // the session already exists; the router takes over.
    if (needsCode == true) context.push('/auth/code?purpose=signup&email=${Uri.encodeComponent(_email.text.trim())}');
  }

  @override
  Widget build(BuildContext context) {
    return _AuthFrame(
      title: 'Create your account',
      intro: 'You’ll set up your business profile next. We’ll email you a code to confirm your address.',
      footer: Center(
        child: TextButton(onPressed: () => context.pushReplacement('/auth/email'), child: const Text('Already have an account? Sign in')),
      ),
      child: AutofillGroup(
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            EvField(
              label: 'Your name',
              controller: _name,
              hint: 'e.g. Mutale Banda',
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.name],
              validator: (v) => (v == null || v.trim().length < 2) ? 'Enter your name' : null,
            ),
            const SizedBox(height: EvSpace.x4),
            _EmailField(controller: _email),
            const SizedBox(height: EvSpace.x4),
            _PasswordField(controller: _password, isNew: true, onSubmitted: _create),
            const SizedBox(height: EvSpace.x5),
            EvButton('Create account', expand: true, loading: _busy, onPressed: _create),
            if (AppConfig.privacyPolicyUrl.isNotEmpty) ...[
              const SizedBox(height: EvSpace.x3),
              Center(
                child: InkWell(
                  onTap: () => launchUrl(Uri.parse(AppConfig.privacyPolicyUrl), mode: LaunchMode.externalApplication),
                  child: Text.rich(
                    TextSpan(style: EvType.caption, children: [
                      const TextSpan(text: 'By creating an account you agree to how Evenda handles your data, described in our '),
                      TextSpan(text: 'privacy policy', style: EvType.caption.copyWith(color: EvColors.forest, decoration: TextDecoration.underline)),
                      const TextSpan(text: '.'),
                    ]),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key, this.email = ''});
  final String email;

  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.email);
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final ok = await guard(context, () async {
      await ref.read(backendProvider).auth.sendPasswordReset(_email.text);
      return true;
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) context.push('/auth/code?purpose=recovery&email=${Uri.encodeComponent(_email.text.trim())}');
  }

  @override
  Widget build(BuildContext context) {
    return _AuthFrame(
      title: 'Forgot your password?',
      intro: 'Enter your account email and we’ll send you a 6-digit code to set a new one.',
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _EmailField(controller: _email, autofocus: widget.email.isEmpty),
          const SizedBox(height: EvSpace.x5),
          EvButton('Send code', expand: true, loading: _busy, onPressed: _send),
        ]),
      ),
    );
  }
}

/// Six-digit email code, used to confirm a new account or to reset a password.
class EmailCodeScreen extends ConsumerStatefulWidget {
  const EmailCodeScreen({super.key, required this.email, required this.recovery});
  final String email;
  final bool recovery;

  @override
  ConsumerState<EmailCodeScreen> createState() => _EmailCodeScreenState();
}

class _EmailCodeScreenState extends ConsumerState<EmailCodeScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_code.text.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = ref.read(backendProvider).auth;
    try {
      if (widget.recovery) {
        await auth.verifyPasswordReset(widget.email, _code.text);
        if (mounted) context.go('/auth/new-password');
      } else {
        await auth.verifyEmail(widget.email, _code.text);
        // Signed in: the router continues to onboarding.
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = EvError.from(e).userMessage);
        _code.clear();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() {
    final auth = ref.read(backendProvider).auth;
    return guard(
      context,
      () => widget.recovery ? auth.sendPasswordReset(widget.email) : auth.resendEmailCode(widget.email),
      success: 'New code sent',
    );
  }

  @override
  Widget build(BuildContext context) {
    return _AuthFrame(
      title: 'Enter the code',
      intro: 'We sent a 6-digit code to ${widget.email}. It can take a minute to arrive — check spam too.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _CodeInput(controller: _code, error: _error != null, onComplete: _verify),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: EvType.small.copyWith(color: EvColors.danger))),
        const SizedBox(height: EvSpace.x5),
        ValueListenableBuilder(
          valueListenable: _code,
          builder: (_, v, _) => EvButton('Verify', expand: true, loading: _busy, onPressed: v.text.length == 6 ? _verify : null),
        ),
        const SizedBox(height: EvSpace.x2),
        _ResendButton(onResend: _resend),
      ]),
    );
  }
}

class NewPasswordScreen extends ConsumerStatefulWidget {
  const NewPasswordScreen({super.key});

  @override
  ConsumerState<NewPasswordScreen> createState() => _NewPasswordScreenState();
}

class _NewPasswordScreenState extends ConsumerState<NewPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final ok = await guard(context, () async {
      await ref.read(backendProvider).auth.updatePassword(_password.text);
      return true;
    }, success: 'Password updated');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) context.go('/launch');
  }

  @override
  Widget build(BuildContext context) {
    return _AuthFrame(
      title: 'Choose a new password',
      child: AutofillGroup(
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _PasswordField(controller: _password, label: 'New password', isNew: true, onSubmitted: _save),
            const SizedBox(height: EvSpace.x5),
            EvButton('Save password', expand: true, loading: _busy, onPressed: _save),
          ]),
        ),
      ),
    );
  }
}

/// Six boxes over a hidden text field, so paste and SMS/email autofill work.
class _CodeInput extends StatefulWidget {
  const _CodeInput({required this.controller, required this.onComplete, this.error = false});
  final TextEditingController controller;
  final VoidCallback onComplete;
  final bool error;

  @override
  State<_CodeInput> createState() => _CodeInputState();
}

class _CodeInputState extends State<_CodeInput> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _focus.requestFocus(),
      child: Stack(children: [
        Opacity(
          opacity: 0,
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            autofocus: true,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            onChanged: (v) {
              if (v.length == 6) widget.onComplete();
            },
          ),
        ),
        ValueListenableBuilder(
          valueListenable: widget.controller,
          builder: (_, v, _) => Row(
            children: [
              for (var i = 0; i < 6; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: AnimatedContainer(
                    duration: EvMotion.of(context, EvMotion.fast),
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: EvColors.warmWhite,
                      borderRadius: EvRadius.smAll,
                      border: Border.all(
                        color: widget.error ? EvColors.danger : (i == v.text.length ? EvColors.forest : EvColors.sand),
                        width: i == v.text.length ? 1.6 : 1,
                      ),
                    ),
                    child: Text(i < v.text.length ? v.text[i] : '', style: EvType.number),
                  ),
                ),
              ],
            ],
          ),
        ),
      ]),
    );
  }
}

/// "Resend code" with a 60-second cooldown that restarts after each resend.
class _ResendButton extends StatefulWidget {
  const _ResendButton({required this.onResend});
  final Future<void> Function() onResend;

  @override
  State<_ResendButton> createState() => _ResendButtonState();
}

class _ResendButtonState extends State<_ResendButton> {
  int _wait = 60;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _timer?.cancel();
    _wait = 60;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_wait <= 1) t.cancel();
      if (mounted) setState(() => _wait--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
        child: TextButton(
          onPressed: _wait > 0
              ? null
              : () async {
                  await widget.onResend();
                  if (mounted) setState(_start);
                },
          child: Text(_wait > 0 ? 'Resend code in ${_wait}s' : 'Resend code'),
        ),
      );
}

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});
  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _form = GlobalKey<FormState>();
  final _phone = TextEditingController();
  bool _busy = false;

  Future<void> _send() async {
    if (!_form.currentState!.validate()) return;
    final e164 = ZambianPhone.normalise(_phone.text)!;
    setState(() => _busy = true);
    final ok = await guard(context, () async {
      await ref.read(backendProvider).auth.sendOtp(e164);
      return true;
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) context.push('/auth/otp?phone=${Uri.encodeComponent(e164)}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(EvSpace.gutter), children: [
          Text('Your mobile number', style: EvType.display),
          const SizedBox(height: EvSpace.x2),
          Text('Use the number your business is reached on. We’ll text you a 6-digit code.', style: EvType.small),
          const SizedBox(height: EvSpace.x6),
          EvPhoneField(controller: _phone, autofocus: true, helper: 'Airtel, MTN or Zamtel'),
          const SizedBox(height: EvSpace.x6),
          EvButton('Send code', expand: true, loading: _busy, onPressed: _send),
        ]),
      ),
    );
  }
}

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key, required this.phone});
  final String phone;
  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _code = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;
  int _wait = 60;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    setState(() => _wait = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_wait <= 1) t.cancel();
      if (mounted) setState(() => _wait--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_code.text.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(backendProvider).auth.verifyOtp(widget.phone, _code.text);
      // The router redirects once the session arrives.
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'That code is not correct or has expired.');
        _code.clear();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    await guard(context, () => ref.read(backendProvider).auth.sendOtp(widget.phone), success: 'New code sent');
    _startTimer();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: ListView(padding: const EdgeInsets.all(EvSpace.gutter), children: [
        Text('Enter the code', style: EvType.display),
        const SizedBox(height: EvSpace.x2),
        Text('Sent to ${ZambianPhone.display(widget.phone)}', style: EvType.small),
        const SizedBox(height: EvSpace.x6),
        GestureDetector(
          onTap: () => _focus.requestFocus(),
          child: Stack(children: [
            Opacity(
              opacity: 0,
              child: TextField(
                controller: _code,
                focusNode: _focus,
                autofocus: true,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                onChanged: (v) {
                  setState(() {});
                  if (v.length == 6) _verify();
                },
              ),
            ),
            ValueListenableBuilder(
              valueListenable: _code,
              builder: (_, v, _) => Row(
                children: [
                  for (var i = 0; i < 6; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: AnimatedContainer(
                        duration: EvMotion.of(context, EvMotion.fast),
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: EvColors.warmWhite,
                          borderRadius: EvRadius.smAll,
                          border: Border.all(
                            color: _error != null ? EvColors.danger : (i == v.text.length ? EvColors.forest : EvColors.sand),
                            width: i == v.text.length ? 1.6 : 1,
                          ),
                        ),
                        child: Text(i < v.text.length ? v.text[i] : '', style: EvType.number),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ]),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: EvType.small.copyWith(color: EvColors.danger))),
        const SizedBox(height: EvSpace.x6),
        EvButton('Verify', expand: true, loading: _busy, onPressed: _code.text.length == 6 ? _verify : null),
        const SizedBox(height: EvSpace.x3),
        Center(
          child: TextButton(
            onPressed: _wait > 0 ? null : _resend,
            child: Text(_wait > 0 ? 'Resend code in ${_wait}s' : 'Resend code'),
          ),
        ),
      ]),
    );
  }
}

class ProfileNameScreen extends ConsumerStatefulWidget {
  const ProfileNameScreen({super.key});
  @override
  ConsumerState<ProfileNameScreen> createState() => _ProfileNameScreenState();
}

class _ProfileNameScreenState extends ConsumerState<ProfileNameScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  bool _busy = false;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    await guard(context, () => ref.read(backendProvider).auth.updateProfileName(_name.text));
    if (mounted) {
      setState(() => _busy = false);
      context.go('/onboarding');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        actions: [TextButton(onPressed: () => ref.read(backendProvider).auth.signOut(), child: const Text('Sign out'))],
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(EvSpace.gutter), children: [
          const Align(alignment: Alignment.centerLeft, child: MascotImage(Mascot.coordinator, size: 96)),
          const SizedBox(height: EvSpace.x4),
          Text('Welcome to Evenda', style: EvType.display),
          const SizedBox(height: EvSpace.x2),
          Text('What should other vendors call you? This appears on quotations and messages.', style: EvType.small),
          const SizedBox(height: EvSpace.x6),
          EvField(
            label: 'Your name',
            controller: _name,
            hint: 'e.g. Mutale Banda',
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            validator: (v) => (v == null || v.trim().length < 2) ? 'Enter your name' : null,
          ),
          const SizedBox(height: EvSpace.x6),
          EvButton('Continue', expand: true, loading: _busy, onPressed: _save),
        ]),
      ),
    );
  }
}
