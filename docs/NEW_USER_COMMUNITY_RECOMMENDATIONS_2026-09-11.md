# New-user community recommendations

The Communities landing page previously displayed only an empty-membership message. Public recommendations were available only after explicitly opening Discover. Both native clients now load the existing empty-query public discovery endpoint after a successful empty membership response, and show its cards under Recommended communities. Existing members keep their membership list. Tapping opens the existing community preview; no automatic memberships are created.

The backend already ranks discoverable official communities first. A live read-only check confirmed Voiid Jobs, Voiid Feedback and Voiid Updates exist, are discoverable, and are not suspended. Jobs is open; Feedback and Updates require approval. Those policies were not changed.

Recommendation failures do not masquerade as an empty membership list; retry is available. Android debounce cancellation now resets its loading flag. No private community visibility or access checks changed.

Scope: Communities landing screen. The user has not yet clarified whether they also meant another Search screen. Native builds and device installation status are recorded in the conversation; testing with a fresh account still remains.
