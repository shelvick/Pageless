// Tailwind configuration for the Pageless operator dashboard.
//
// `content` lists every place a class name could appear so unused utilities
// are tree-shaken out of `priv/static/assets/app.css`.

const path = require("path");

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/pageless_web.ex",
    "../lib/pageless_web/**/*.*ex",
  ],
  theme: {
    extend: {},
  },
  plugins: [],
};
