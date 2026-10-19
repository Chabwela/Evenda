import 'dart:async';

/// Structured application error. Backends translate their failures into
/// these codes so screens can show a specific message and recovery action.
class EvError implements Exception {
  const EvError(this.code, [this.message, this.detail]);

  final String code;
  final String? message;
  final Map<String, dynamic>? detail;

  bool get isOffline => code == 'offline';
  bool get isForbidden => code == 'forbidden' || code == 'admin_forbidden';

  /// Human message for a known backend code.
  String get userMessage => message ?? _messages[code] ?? 'Something went wrong. Please try again.';

  static const _messages = {
    'offline': 'Couldn’t reach Evenda. Check your internet connection and try again.',
    'timeout': 'The request took too long. Check your connection and try again.',
    'not_authenticated': 'Your session has ended. Please sign in again.',
    'forbidden': 'You do not have permission to do that for this business.',
    'admin_forbidden': 'Your admin role does not allow this action.',
    'insufficient_availability': 'Not enough stock is available for those dates.',
    'quotation_expired': 'This quotation has expired. Ask the supplier for a revised one.',
    'quotation_not_open': 'This quotation is no longer open.',
    'request_closed': 'This request is closed.',
    'dates_in_past': 'Choose a date from today onwards.',
    'invalid_transition': 'That status change is not allowed at this stage.',
    'onboarding_incomplete': 'A few required details are still missing.',
    'reason_required': 'Give a short reason for this action.',
    'location_outside_zambia': 'Choose a location inside Zambia.',
    'not_a_recipient': 'This request was not sent to your business.',
    'offer_not_open': 'This offer is no longer open.',
    'listing_not_from_supplier': 'That listing does not belong to this supplier.',
    'invalid_otp': 'That code is not correct or has expired.',
    'invalid_credentials': 'Email or password is incorrect.',
    'email_not_confirmed': 'Confirm your email first. We have sent you a new code.',
    'email_taken': 'An account with this email already exists. Sign in instead.',
    'weak_password': 'Choose a stronger password: at least 8 characters with letters and numbers.',
    'same_password': 'Your new password must be different from the old one.',
    'rate_limited': 'Too many attempts. Wait a few minutes and try again.',
    'signup_disabled': 'New accounts are not open right now.',
    'otp_not_configured': 'Phone sign-in is not configured on the server yet.',
    'items_required': 'Add at least one item.',
    'stock_below_out_of_service': 'Total stock cannot be lower than damaged and inspection counts.',
    'documents_required': 'Upload at least one document first.',
    'documents_not_reviewed': 'Accept at least one verification document before verifying this business.',
    'invalid_status': 'That status is not allowed here.',
    'not_found': 'Not found, or you do not have access.',
  };

  static EvError from(Object e) {
    if (e is EvError) return e;
    if (e is TimeoutException) return const EvError('timeout');
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('ClientException') || s.contains('Failed to fetch')) {
      return const EvError('offline');
    }
    return EvError('unknown', null, {'raw': s});
  }

  @override
  String toString() => 'EvError($code${message != null ? ': $message' : ''})';
}
