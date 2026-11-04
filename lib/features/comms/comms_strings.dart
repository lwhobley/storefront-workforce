import '../../core/i18n/strings.dart';

/// Inbox words in English and Spanish (employee-facing).
extension CommsStrings on T {
  String get inbox => es ? 'Bandeja' : 'Inbox';
  String get messagesTab => es ? 'Mensajes' : 'Messages';
  String get announcementsTab => es ? 'Avisos' : 'Announcements';
  String get notificationsTab => es ? 'Alertas' : 'Notifications';
  String get urgent => es ? 'Urgente' : 'Urgent';
  String get newLabel => es ? 'Nuevo' : 'New';
  String get markAllRead => es ? 'Marcar todo como leído' : 'Mark all read';
  String get noMessages => es ? 'No tiene mensajes.' : 'No messages yet.';
  String get noAnnouncements => es ? 'No hay avisos.' : 'No announcements.';
  String get noNotifications => es ? 'No hay alertas.' : 'No notifications.';
  String fromName(String name) => es ? 'De $name' : 'From $name';
  String toLabel(String label) => es ? 'Para: ${_audience(label)}' : 'To: $label';
  String _audience(String label) => switch (label) {
        'Everyone' => 'Todos',
        'Managers and leads' => 'Gerentes y líderes',
        _ => label.startsWith('Level: ') ? 'Nivel: ${label.substring(7)}' : label,
      };

  String get policy => es ? 'Política' : 'Policy';
  String get needsAck => es ? 'Necesita su confirmación' : 'Needs your acknowledgment';
  String get iHaveRead => es ? 'Lo he leído' : 'I have read this';
  String get signPolicy => es ? 'Firmar la política' : 'Sign the policy';
  String get typeFullName => es ? 'Escriba su nombre completo' : 'Type your full name';
  String get signNote => es
      ? 'Al escribir su nombre confirma que leyó y entiende esta política.'
      : 'Typing your name confirms you have read and understand this policy.';
  String get sign => es ? 'Firmar' : 'Sign';
  String acknowledgedOn(String when) => es ? 'Confirmado $when' : 'Acknowledged $when';
  String signedAs(String name) => es ? 'Firmado: $name' : 'Signed: $name';
  String get openDocument => es ? 'Abrir documento' : 'Open document';
  String get linkCopied => es ? 'Enlace copiado. Péguelo en su navegador.' : 'Link copied. Paste it in your browser.';
  String get thanks => es ? 'Gracias. Quedó registrado.' : 'Thanks. That is on record.';
  String expires(String when) => es ? 'Vence $when' : 'Until $when';

  // Settings
  String get notificationSettings => es ? 'Cómo recibir avisos' : 'How you get notified';
  String get pushOnPhone => es ? 'Notificaciones en el teléfono' : 'Phone notifications';
  String get pushHelp => es ? 'Cuando la app está instalada en su teléfono.' : 'When the app is installed on your phone.';
  String get emailCopies => es ? 'Copias por correo' : 'Email copies';
  String get emailHelp => es ? 'Mensajes urgentes, políticas y recordatorios.' : 'Urgent messages, policies, and reminders.';
  String get noEmailOnFile => es ? 'No hay correo registrado. Pida a su gerente que lo agregue.' : 'No email on file. Ask your manager to add one.';
  String get emailAddress => es ? 'Correo electrónico' : 'Email address';
  String get quietHours => es ? 'Horas de silencio' : 'Quiet hours';
  String get quietHelp => es
      ? 'Las notificaciones y correos esperan hasta que terminen. Los mensajes urgentes llegan igual.'
      : 'Phone notifications and email wait until they end. Urgent messages still come through.';
  String get quietFrom => es ? 'Desde' : 'From';
  String get quietTo => es ? 'Hasta' : 'Until';
  String get save => es ? 'Guardar' : 'Save';
  String get saved => es ? 'Guardado' : 'Saved';

  String get justNow => es ? 'ahora' : 'just now';
  String minutesAgo(int m) => es ? 'hace $m min' : '$m min ago';
  String hoursAgo(int h) => es ? 'hace $h h' : '$h h ago';
  String get yesterday => es ? 'ayer' : 'yesterday';

  static const _monthsEn = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static const _monthsEs = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

  /// A local date like 'Nov 3' or '3 nov'.
  String shortDate(DateTime local) =>
      es ? '${local.day} ${_monthsEs[local.month - 1]}' : '${_monthsEn[local.month - 1]} ${local.day}';

  /// '5 min ago', '2 h ago', 'yesterday', 'Nov 3'. [local] and [nowLocal] are venue time.
  String ago(DateTime local, DateTime nowLocal) {
    final d = nowLocal.difference(local);
    if (d.inMinutes < 1) return justNow;
    if (d.inMinutes < 60) return minutesAgo(d.inMinutes);
    final sameDay = local.year == nowLocal.year && local.month == nowLocal.month && local.day == nowLocal.day;
    if (sameDay || d.inHours < 6) return hoursAgo(d.inHours);
    final y = nowLocal.subtract(const Duration(days: 1));
    if (local.year == y.year && local.month == y.month && local.day == y.day) return yesterday;
    return shortDate(local);
  }
}
