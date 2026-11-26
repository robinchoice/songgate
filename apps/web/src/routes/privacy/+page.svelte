<script lang="ts">
  import LegalPage from '#lib/components/LegalPage.svelte';
</script>

<LegalPage title="Privacy policy" lang="en">
  <p>Songgate works without sign-up, without ads and without tracking. An account is optional and only available in the apps. This policy applies to the website and the apps for iOS and Android.</p>

  <h2>Controller</h2>
  <p>Robin Wahl, Pleasance, Bugginger Straße 37, 79114 Freiburg, Germany<br />Email: <a href="mailto:hello@pleasance.org">hello@pleasance.org</a></p>

  <h2>Hosting</h2>
  <p>Website and server run at Hetzner Online GmbH, servers located in Germany. Each request creates technically necessary server log files (IP address, time, requested address, browser or app version). They serve only secure operation and are not analysed. Legal basis is Art. 6(1)(f) GDPR.</p>

  <h2>Converting songs</h2>
  <p>When you paste a link or share it from another app, Songgate sends it to our server. The server reads title and artist from the source platform and looks the song up on the target platform. To do so it queries public interfaces of these providers:</p>
  <ul>
    <li><strong>Apple</strong> (Apple Distribution International, Ireland): iTunes Search API for songs on Apple Music and podcasts on Apple Podcasts</li>
    <li><strong>YouTube</strong> (Google Ireland Limited, Ireland): search and details of songs and podcasts from YouTube Music</li>
    <li><strong>ListenBrainz</strong> (MetaBrainz Foundation, USA): maps title and artist to the matching Spotify songs</li>
    <li><strong>Spotify</strong> (Spotify AB, Sweden) and <strong>Deezer</strong> (Deezer S.A., France): details of songs and podcasts from links of these services and the search for podcasts</li>
    <li><strong>TIDAL</strong> (TIDAL Music AS, Norway): song details for TIDAL links and search on TIDAL</li>
  </ul>
  <p>Songgate queries nothing at Amazon Music, it only builds a link to its search.</p>
  <p>Only the link or title, artist and album are sent, for podcasts the name of the show and the title of the episode. Our server makes these requests, so your IP address and other details about you do not reach the providers. We don't store links or results permanently. So that shared song links load quickly, the server keeps the result in memory for up to 24 hours, without any reference to you. Legal basis is Art. 6(1)(b) GDPR.</p>
  <p>Your device loads the cover images of the results directly from the platforms' servers (Apple, Google, Spotify, Deezer, TIDAL), which see your IP address. When you open a song in a music app or on a platform, its privacy policy applies.</p>

  <h2>Settings on your device</h2>
  <p>Songgate stores your preferred target platform, the service you last opened on a shared song page, your contacts and groups (name and music service) and, if given, your email address for feedback locally on your device. Without an account, contacts never reach our server. An invite link only contains the name and service you enter yourself, with an account also the random ID of your profile. We only set a cookie when you switch the language in the footer: it keeps your choice for a year.</p>

  <h2>Account (optional, app only)</h2>
  <p>With an account your contacts and groups stay with you on all your devices. You log in with a code we send by email through Proton AG (Switzerland). For this we store your email address, the name and music service of your profile, your contacts and groups (name, music service and, when linked, the profile ID) and a session key for each login, of which we only keep a hash. The code is also stored only as a hash and expires after 15 minutes. Against abuse, your device solves a small task before each code request (ALTCHA, without cookies and without third parties), and we count requests per IP address and email address; these counters are deleted after one hour at the latest.</p>
  <p>Anyone who saved you through your invite can fetch the name and music service of your profile by its random ID, so your songs still arrive in the right place after you switch services. Nobody sees your email address. There is no search by name.</p>
  <p>You can delete the account at any time in the app under “Contacts” → your profile → “Delete account”. We then delete account, profile, contacts and sessions at once; the contacts on your device stay. A session ends when you log out or after a year without use. The legal basis is Art. 6(1)(b) GDPR.</p>

  <h2>Finding contacts by phone number (optional, account only)</h2>
  <p>If you add your phone number to your account, we send you a confirmation code by SMS through seven communications GmbH &amp; Co. KG (Kiel, Germany). For this the number goes to that provider once. We do not store the number, only a key value we compute from it with a secret server key (OPRF according to RFC 9497). Without that key the number cannot be recovered from it, not even in a data leak. The code is stored only as a hash and expires after 15 minutes. With a confirmed number you are findable: anyone who has your number in their address book and uses Songgate sees you with the name from their own address book and the music service of your profile. If there is no name in the address book, the app shows your profile name.</p>
  <p>When you tap “Find contacts”, the app asks for access to your address book. Your device blinds the numbers before they leave it; our server only applies its key and does not see a single number, not even those of people without Songgate. Your device compares the result itself with an encrypted list of all findable accounts whose entries (profile ID, name and music service) can only be opened by someone who knows the respective number. The search sends no matches to our server. Against abuse, each confirmed number checks at most 1000 numbers a day; the counters expire after 24 hours. Only your device remembers which numbers have been checked.</p>
  <p>You can remove the number at any time in your account under “No longer findable”; we then delete the key value and open codes at once, likewise when you delete the account. Expired codes are deleted with the next code request. The legal basis is Art. 6(1)(a) GDPR.</p>

  <h2>Feedback</h2>
  <p>With “Give feedback” you can send us bugs and ideas. We transmit your message, a screenshot if you like, your email address and technical details (page, platform, device, window size, latest error messages). The report is stored on our server and forwarded to us by email via Proton AG (Switzerland). The European Commission has issued an adequacy decision for Switzerland. Against abuse we count reports per IP address; this counter is deleted after one hour.</p>
  <p>We only use these details to handle the report and to reply to you. We delete them once the report is done, or on your request. Legal basis is Art. 6(1)(f) GDPR, for the optional email address Art. 6(1)(a) GDPR.</p>

  <h2>Error reports</h2>
  <p>When something crashes, Songgate sends a technical error report to our own GlitchTip installation at Hetzner in Germany. Website, server and apps use Sentry's open-source SDK for this. Reports go only to our server, not to Functional Software, Inc. (Sentry). They contain the error message, code location, app or browser version, operating system and device type, but no cookies, input or personal data, and are deleted after 90 days. Legal basis is Art. 6(1)(f) GDPR.</p>

  <h2>Your rights</h2>
  <p>You have the right to access, rectification, erasure, restriction of processing, data portability and objection. Write to <a href="mailto:hello@pleasance.org">hello@pleasance.org</a>. You can also lodge a complaint with a data protection authority, for example the State Commissioner for Data Protection and Freedom of Information Baden-Württemberg.</p>

  <p>Last updated: November 2026</p>
</LegalPage>
