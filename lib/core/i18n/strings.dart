import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Employee-facing words in English and Spanish. Kept short so they read at a glance on
/// a phone in a loud concourse. Manager screens are English for now.
class T {
  const T(this.lang);

  final String lang;
  bool get es => lang == 'es';

  String get appName => 'Storefront Workforce';
  String get enterPin => es ? 'Ingrese su PIN' : 'Enter your PIN';
  String get pinHelp => es ? 'Su PIN de 6 dígitos lo da su gerente.' : 'Your 6-digit PIN comes from your manager.';
  String get signIn => es ? 'Entrar' : 'Sign in';
  String get signOut => es ? 'Salir' : 'Sign out';
  String get clear => es ? 'Borrar' : 'Clear';
  String get language => es ? 'English' : 'Español';

  String get clockIn => es ? 'Marcar entrada' : 'Clock in';
  String get clockOut => es ? 'Marcar salida' : 'Clock out';
  String get startBreak => es ? 'Iniciar descanso' : 'Start break';
  String get startMeal => es ? 'Iniciar comida' : 'Start meal';
  String get endBreak => es ? 'Terminar descanso' : 'End break';
  String get onBreak => es ? 'En descanso' : 'On break';
  String get working => es ? 'Trabajando' : 'Working';
  String get notClockedIn => es ? 'Sin marcar entrada' : 'Not clocked in';
  String get clockedOut => es ? 'Salida marcada' : 'Clocked out';
  String get sentHome => es ? 'Enviado a casa' : 'Sent home';
  String get callTime => es ? 'Hora de llegada' : 'Call time';
  String get yourPost => es ? 'Su puesto' : 'Your post';
  String get station => es ? 'Estación' : 'Station';
  String get noShiftToday => es ? 'No tiene turno hoy.' : 'No shift today.';
  String get upcoming => es ? 'Próximos turnos' : 'Upcoming shifts';
  String get takePhoto => es ? 'Tome una foto para confirmar' : 'Take a photo to confirm';
  String get photoNeeded => es ? 'Se necesita una foto.' : 'A photo is needed.';
  String get savedOffline => es ? 'Guardado en este teléfono. Se enviará al tener señal.' : 'Saved on this phone. It will send when you have signal.';
  String waitingToSend(int n) => es ? '$n por enviar' : '$n waiting to send';
  String get allSent => es ? 'Todo enviado' : 'All sent';
  String get done => es ? 'Listo' : 'Done';
  String get late => es ? 'Tarde' : 'Late';
  String minutesLate(int m) => es ? '$m min tarde' : '$m min late';
  String breakDueIn(int m) => es ? 'Descanso en $m min' : 'Break due in $m min';
  String get breakDueNow => es ? 'Tome su descanso ahora' : 'Take your break now';
  String hoursWorked(String h) => es ? '$h horas trabajadas' : '$h hours worked';
  String get outsideVenue => es ? 'Está fuera del área del lugar.' : 'You are outside the venue area.';
  String get tooEarly => es ? 'Todavía es muy temprano para marcar.' : 'It is too early to clock in.';

  // Kiosk
  String get kioskTitle => es ? 'Reloj de entrada' : 'Time clock';
  String get kioskPrompt => es ? 'Escriba su PIN para marcar' : 'Type your PIN to clock in or out';
  String hello(String name) => es ? 'Hola, $name' : 'Hi, $name';
  String get cancel => es ? 'Cancelar' : 'Cancel';
  String get confirmed => es ? 'Confirmado' : 'Confirmed';
  String get kioskOffline => es ? 'Sin conexión: se guarda y se envía después.' : 'Offline: punches are saved and sent later.';
}

final languageProvider = NotifierProvider<LanguageController, String>(LanguageController.new);

class LanguageController extends Notifier<String> {
  @override
  String build() => 'en';

  void set(String lang) => state = lang == 'es' ? 'es' : 'en';
  void toggle() => state = state == 'es' ? 'en' : 'es';
}

final stringsProvider = Provider<T>((ref) => T(ref.watch(languageProvider)));
