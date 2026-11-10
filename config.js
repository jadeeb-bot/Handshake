// Supabase project address and public key (Project Settings → API Keys).
// Both values are meant to be public: the database's own rules decide what anyone can do.
window.HANDSHAKE_CONFIG = {
  supabaseUrl: "https://akgrilycmjrskuqelhju.supabase.co",
  supabaseAnonKey: "sb_publishable_Yayho6daHucOZ045Wq0j6Q_SHDGTdYu",
  // The public website. Invites from the iPhone app link here.
  siteUrl: "https://handshake-rho-ten.vercel.app/",
  // Public half of the push notification key pair (the private half lives in Supabase secrets).
  vapidPublicKey: "BGWmKz-IjaFjdRMQhrlOz1qkp2I96WGJ_2Ev2N0u5l1iAmt1qQEcMCJjXvyEmlbATFJ2myFuXuoaUSO603HcDx0",
};
