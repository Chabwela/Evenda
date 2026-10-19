import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('demo vendor can sign in with email and password', () async {
    final backend = DemoBackend();

    final session = await backend.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');

    expect(session.userId, 'u-kabwata');
    expect(backend.auth.current?.userId, 'u-kabwata');
  });

  test('demo business can invite a team member by email', () async {
    final backend = DemoBackend();
    await backend.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');

    await backend.business.inviteMember('b-kabwata', 'amina@demo.evenda.zm', 'Amina Phiri', MemberRole.staff);

    final members = await backend.business.team('b-kabwata');
    expect(members.any((m) => m.email == 'amina@demo.evenda.zm' && m.role == MemberRole.staff), isTrue);
  });
}
