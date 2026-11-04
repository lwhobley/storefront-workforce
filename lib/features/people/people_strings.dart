import '../../core/i18n/strings.dart';

/// Employee-facing words for the Me screen (hours, tips, onboarding, profile), in
/// English and Spanish.
extension PeopleStrings on T {
  String get me => es ? 'Yo' : 'Me';
  String get hoursTab => es ? 'Horas' : 'Hours';
  String get tipsTab => es ? 'Propinas' : 'Tips';
  String get onboardingTab => es ? 'Incorporación' : 'Onboarding';
  String get profileTab => es ? 'Perfil' : 'Profile';

  // Hours
  String get payPeriod => es ? 'Periodo de pago' : 'Pay period';
  String get previousPeriod => es ? 'Periodo anterior' : 'Previous period';
  String get nextPeriod => es ? 'Periodo siguiente' : 'Next period';
  String get hoursWorkedLabel => es ? 'Horas trabajadas' : 'Hours worked';
  String get eventsLabel => es ? 'Eventos' : 'Events';
  String get breaksLabel => es ? 'Descansos' : 'Breaks';
  String get noHoursInPeriod => es ? 'No hay horas en este periodo.' : 'No hours in this pay period.';
  String get stillClockedIn => es ? 'Todavía con entrada marcada' : 'Still clocked in';
  String get inLabel => es ? 'Entrada' : 'In';
  String get outLabel => es ? 'Salida' : 'Out';
  String get otherWork => es ? 'Trabajo sin evento' : 'Work with no event';
  String get hoursNote => es
      ? 'Horas de sus marcas de entrada y salida. Los descansos pagados de 20 minutos o menos cuentan como tiempo trabajado. ¿Preguntas sobre su pago? Hable con su gerente.'
      : 'Hours from your clock-ins. Paid breaks of 20 minutes or less count as time worked. Questions about pay? Ask your manager.';
  String paidOn(String date) => es ? 'Día de pago: $date' : 'Payday: $date';

  // Tips
  String get tipsTotal => es ? 'Propinas en total' : 'Tips in total';
  String get noTips => es ? 'Todavía no hay propinas.' : 'No tips yet.';
  String get tipsNote => es
      ? 'Propinas del fondo de su puesto, repartidas por horas trabajadas. Se pagan con su cheque.'
      : 'Tips from your stand\'s pool, shared by hours worked. Paid with your paycheck.';
  String hoursShort(String h) => es ? '$h h' : '$h h';

  // Onboarding
  String stepsDone(int done, int total) => es ? '$done de $total listos' : '$done of $total done';
  String get allDone => es ? 'Todo listo. ¡Gracias!' : 'All done. Thank you!';
  String get continueOnboarding => es ? 'Continuar' : 'Continue';
  String get onboardingBanner => es ? 'Termine su incorporación' : 'Finish your onboarding';
  String stepName(String code, String fallback) => switch (code) {
        'application' => es ? 'Solicitud' : 'Application',
        'policies' => es ? 'Políticas' : 'Policies',
        'waiver' => es ? 'Exención de voluntario' : 'Volunteer waiver',
        'age_confirmation' => es ? 'Confirmación de edad' : 'Age confirmation',
        'certifications' => es ? 'Tarjetas de certificación' : 'Certification cards',
        'training' => es ? 'Capacitación' : 'Training',
        'paycom' => es ? 'Incorporación en Paycom' : 'Paycom onboarding',
        _ => fallback,
      };
  String stepHelp(String code, String fallback) => switch (code) {
        'application' => es ? 'Sus datos de contacto, contacto de emergencia, talla de uniforme e idioma.' : 'Your contact details, emergency contact, uniform size and language.',
        'policies' => es ? 'Lea y firme las políticas escribiendo su nombre.' : 'Read and sign the policies by typing your name.',
        'waiver' => es ? 'Lea y firme la exención. Si tiene menos de 18 años, su padre, madre o tutor también firma.' : 'Read and sign the waiver. Under 18? A parent or guardian signs too.',
        'age_confirmation' => es ? 'Su fecha de nacimiento, para seguir las reglas para menores.' : 'Your birth date, so your schedule follows the rules for minors.',
        'certifications' => es ? 'Una foto de cada tarjeta que necesitan sus puestos.' : 'A photo of each card your roles need.',
        'training' => es ? 'Su entrenador marca cada tema cuando lo termina.' : 'Your trainer checks off each topic as you finish it.',
        'paycom' => es ? 'Se hace en Paycom (I-9, W-4, depósito directo). Su gerente lo marca aquí.' : 'Done in Paycom (I-9, W-4, direct deposit). Your manager marks it here.',
        _ => fallback,
      };
  String statusLabel(String code) => switch (code) {
        'submitted' => es ? 'En revisión' : 'Being checked',
        'approved' => es ? 'Aprobado' : 'Approved',
        'needs_changes' => es ? 'Necesita cambios' : 'Needs changes',
        'complete' => es ? 'Listo' : 'Done',
        _ => es ? 'Pendiente' : 'To do',
      };
  String get managerSays => es ? 'Su gerente dice:' : 'Your manager says:';
  String get managerDoesThis => es ? 'Su gerente completa este paso.' : 'Your manager completes this step.';
  String itemsDone(int n, int total) => es ? '$n de $total temas' : '$n of $total topics';
  String get submit => es ? 'Enviar' : 'Submit';
  String get saved => es ? 'Guardado' : 'Saved';
  String get close => es ? 'Cerrar' : 'Close';

  // Application form
  String get address => es ? 'Dirección' : 'Home address';
  String get phone => es ? 'Teléfono' : 'Phone';
  String get email => es ? 'Correo electrónico' : 'Email';
  String get emergencyName => es ? 'Contacto de emergencia' : 'Emergency contact';
  String get emergencyPhone => es ? 'Teléfono de emergencia' : 'Emergency contact phone';
  String get uniformSize => es ? 'Talla de uniforme' : 'Uniform size';
  String get preferredLanguage => es ? 'Idioma preferido' : 'Preferred language';
  String get notes => es ? 'Notas (opcional)' : 'Notes (optional)';
  String get requiredField => es ? 'Obligatorio' : 'Required';

  // Documents
  String get typeYourName => es ? 'Escriba su nombre completo' : 'Type your full name';
  String get guardianName => es ? 'Nombre del padre, madre o tutor' : 'Parent or guardian\'s full name';
  String get iAmAdult => es ? 'Tengo 18 años o más' : 'I am 18 or older';
  String get sign => es ? 'Firmar' : 'Sign';
  String signedBy(String name, String date) => es ? 'Firmado por $name el $date' : 'Signed by $name on $date';
  String get nameMustMatch => es ? 'Escriba su nombre como aparece en su registro.' : 'Type your name as it appears on your record.';

  // Cards
  String get takePhotoOfCard => es ? 'Tomar foto' : 'Take photo';
  String get choosePhoto => es ? 'Elegir foto' : 'Choose photo';
  String get cardNumber => es ? 'Número de tarjeta' : 'Card number';
  String get expiresOn => es ? 'Vence' : 'Expires';
  String get chooseDate => es ? 'Elegir fecha' : 'Choose date';
  String get waitingForCheck => es ? 'Esperando revisión del gerente' : 'Waiting for a manager to check';
  String get photoAdded => es ? 'Foto agregada' : 'Photo added';
  String get addPhotoFirst => es ? 'Agregue una foto de la tarjeta.' : 'Add a photo of the card.';
  String get nothingNeeded => es ? 'Nada pendiente para sus puestos.' : 'Nothing needed for your roles.';

  // Birth date
  String get birthDate => es ? 'Fecha de nacimiento' : 'Birth date';
  String get birthDateOnFile => es ? 'Tenemos su fecha de nacimiento.' : 'Your birth date is on file.';

  // Profile
  String get workerTypeLabel => es ? 'Tipo' : 'Type';
  String get updatedSignAgain => es ? 'Este documento cambió desde que lo firmó. Fírmelo de nuevo.' : 'This document changed since you signed it. Please sign it again.';
  String get employeeNumber => es ? 'Número de empleado' : 'Employee number';
  String get roles => es ? 'Puestos' : 'Roles';
  String get certifications => es ? 'Certificaciones' : 'Certifications';
  String get contact => es ? 'Contacto' : 'Contact';
  String get noCertsNeeded => es ? 'Sus puestos no necesitan tarjetas.' : 'Your roles need no cards.';
  String get certOk => es ? 'Vigente' : 'Current';
  String get certExpiring => es ? 'Vence pronto' : 'Expiring soon';
  String get certExpired => es ? 'Vencida' : 'Expired';
  String get certMissing => es ? 'Falta' : 'Missing';
  String get noExpiry => es ? 'Sin vencimiento' : 'No expiry';
  String get changeInApplication => es ? 'Para cambiar estos datos, actualice su solicitud en Incorporación.' : 'To change these, update your application under Onboarding.';
  String get askManagerToChange => es ? 'Para cambiar estos datos, hable con su gerente.' : 'To change these, ask your manager.';
  String get english => 'English';
  String get spanish => 'Español';
  String typeName(String code) => switch (code) {
        'temp' => es ? 'Temporal' : 'Temp',
        'npo' => es ? 'Voluntario' : 'Volunteer',
        _ => es ? 'Personal' : 'Staff',
      };
}
