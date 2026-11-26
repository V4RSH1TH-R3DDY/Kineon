#ifndef NEUROSENSE_H
#define NEUROSENSE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Input is UTF-8, NUL-terminated JSON. NULL indicates a parsing or runtime error.
 * A valid but unusable window returns JSON with status "insufficient_data".
 * Free each non-NULL response once with neurosense_free_json_v1. */
char *neurosense_score_json_v1(const char *input);
void neurosense_free_json_v1(char *output);

#ifdef __cplusplus
}
#endif
#endif
