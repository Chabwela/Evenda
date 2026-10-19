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
    final demo = ref.watch(backendProvider).isDemo;
    return Scaffold(
      backgroundColor: EvColors.forest,
      appBar: AppBar(backgroundColor: EvColors.forest, foregroundColor: EvColors.inkOnDark),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(EvSpace.gutter), children: [
            const Align(alignment: Alignment.centerLeft, child: EvendaLogo(size: 30, onDark: true)),
            const SizedBox(height: EvSpace.x4),
            Text('Platform administration', style: EvType.display.copyWith(color: EvColors.inkOnDark)),
            const SizedBox(height: EvSpace.x2),
            Text('For Evenda staff. Access is granted by an administrator and every action is recorded.', style: EvType.small.copyWith(color: EvColors.sand)),
            const SizedBox(height: EvSpace.x6),
            Container(
              padding: const EdgeInsets.all(EvSpace.x5),
              decoration: BoxDecoration(color: EvColors.warmWhite, borderRadius: EvRadius.lgAll),
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  EvField(label: 'Work email', controller: _email, keyboardType: TextInputType.emailAddress, textCapitalization: TextCapitalization.none, prefixIcon: LucideIcons.mail),
                  const SizedBox(height: EvSpace.x4),
                  const EvFieldLabel('Password'),
                  TextField(
                    controller: _password,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _signIn(),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(LucideIcons.keyRound, size: 18, color: EvColors.ink3),
                      suffixIcon: IconButton(icon: Icon(_obscure ? LucideIcons.eye : LucideIcons.eyeOff, size: 18), onPressed: () => setState(() => _obscure = !_obscure)),
                    ),
                  ),
                  const SizedBox(height: EvSpace.x5),
                  EvButton('Sign in', expand: true, loading: _busy, onPressed: _signIn),
                ]),
              ),
            ),
            if (demo) ...[
              const SizedBox(height: EvSpace.x5),
              Container(
                padding: const EdgeInsets.all(EvSpace.x4),
                decoration: BoxDecoration(color: EvColors.bronzeTint, borderRadius: EvRadius.mdAll),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(LucideIcons.flaskConical, size: 16, color: EvColors.bronzeDeep),
                    const SizedBox(width: 6),
                    Text('Demo admin accounts', style: EvType.smallStrong.copyWith(color: EvColors.bronzeDeep)),
                  ]),
                  const SizedBox(height: 6),
                  Text('Password for all: demo-admin. Each role sees only what its permissions allow.', style: EvType.caption.copyWith(color: EvColors.bronzeDeep)),
                  const SizedBox(height: 8),
                  for (final e in const ['super@demo.evenda.zm', 'moderator@demo.evenda.zm', 'support@demo.evenda.zm', 'finance@demo.evenda.zm'])
                    InkWell(
                      onTap: () => setState(() {
                        _email.text = e;
                        _password.text = 'demo-admin';
                      }),
                      child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(e, style: EvType.small.copyWith(color: EvColors.bronzeDeep, decoration: TextDecoration.underline))),
                    ),
                ]),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
