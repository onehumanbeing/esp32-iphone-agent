#pragma once
// The StopWatch's own words on screen, in its language (English by default, toggled on the status page and kept in
// NVS). Text the app sends (the run's line, the picks, what was heard) is shown as it comes. Pure C, host tested.
#ifdef __cplusplus
extern "C" {
#endif

enum sw_lang { SW_EN, SW_ZH, SW_LANGS };

enum sw_text_id {
  SWT_BATTERY,      // "%u" follows
  SWT_BATTERY_NONE,
  SWT_BT_ON, SWT_BT_OFF,
  SWT_APP_ON, SWT_APP_OFF,
  SWT_FIRMWARE,     // the version follows
  SWT_LANGUAGE,     // the status page's language row: tap it (or yellow) to switch
  SWT_PAUSED, SWT_HELP, SWT_HELP_HINT, SWT_DONE, SWT_NOT_DONE, SWT_STUCK,
  SWT_CONFIRM, SWT_CONFIRM_HINT, SWT_SHAKE, SWT_SHAKE_HINT, SWT_RELEASE_CANCELS,
  SWT_LISTENING, SWT_LISTEN_HINT, SWT_TRANSCRIBING, SWT_RUN_HINT, SWT_TELL_HINT, SWT_SENT,
  SWT_ERR_NONE, SWT_ERR_DENIED, SWT_ERR_UNAVAILABLE, SWT_ERR_START, SWT_ERR_TIMEOUT, SWT_ERR_OTHER,
  SWT_TOTAL,  // "%d steps - %s": steps and time at the finish
  SWT_CONFIRM_STEP, SWT_HELP_KEYS, SWT_CONFIRM_KEYS, SWT_TAKEOVER_HINT,
  SWT_CHARGING, SWT_LOW_BATTERY,  // "%u" (the battery) in each
  SWT_COUNT
};

const char *sw_text(int lang, int id);  // never NULL; an unknown lang reads as English
int sw_lang_next(int lang);             // the language the switch goes to
const char *sw_locale(int lang);        // speech recognition for this language: "en-US", "zh-CN"

#ifdef __cplusplus
}
#endif
