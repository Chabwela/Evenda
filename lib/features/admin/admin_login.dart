import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../design/ev.dart';

/// Admin sign-in. There is no admin registration: roles exist only as rows in
/// platform_admins, written by Evenda staff with the service role. The role
/// shown after sign-in comes from the server, never from this screen.
class AdminLoginScreen extends ConsumerStatefulWidget {
  const AdminLoginScreen({super.key});
  @override
  ConsumerState<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends ConsumerState<AdminLoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  Future<void> _signIn() async {
    setState(() => _busy = true);
    final s = await guard(context, () => ref.read(backendProvider).admin.signIn(_email.text, _password.text));
    if (!mounted) return;
    setState(() => _busy = false);
    if (s != null) context.pushReplacement('/admin');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(EvSpace.gutter), children: [
            const Align(alignment: Alignment.centerLeft, child: EvendaLogo(size: 24)),
            const SizedBox(height: EvSpace.x8),
            Text('Platform administration', style: EvType.display),
            const SizedBox(height: EvSpace.x2),
            Text('For Evenda staff. Access is granted by an administrator and every action is recorded.', style: EvType.small),
            const SizedBox(height: EvSpace.x6),
            // Same form treatment as the vendor sign-in: on the page, no card.
            AutofillGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                EvField(
                  label: 'Work email',
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  textCapitalization: TextCapitalization.none,
                  autofillHints: const [AutofillHints.email, AutofillHints.username],
                  autocorrect: false,
                ),
                const SizedBox(height: EvSpace.x4),
                const EvFieldLabel('Password'),
                TextField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _signIn(),
                  decoration: InputDecoration(
                    suffixIcon: IconButton(tooltip: _obscure ? 'Show password' : 'Hide password', icon: Icon(_obscure ? LucideIcons.eye : LucideIcons.eyeOff, size: 18), onPressed: () => setState(() => _obscure = !_obscure)),
                  ),
                ),
                const SizedBox(height: EvSpace.x6),
                EvButton('Sign in', expand: true, loading: _busy, onPressed: _signIn),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
