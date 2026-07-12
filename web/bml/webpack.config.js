const path = require("path");
const webpack = require("webpack");

module.exports = {
  entry: {
    bml: "./src/index.ts",
  },
  output: {
    path: path.resolve(__dirname, "dist"),
    filename: "[name].js",
  },
  module: {
    rules: [
      {
        test: /\.tsx?$/,
        use: {
          loader: "ts-loader",
          options: {
            // web-bml is vendored as-is; don't fail our build on its own type nuances.
            transpileOnly: true,
          },
        },
      },
      {
        test: /\.css$/,
        type: "asset/source",
      },
      {
        test: /\.woff2$/,
        type: "asset/inline",
      },
    ],
  },
  resolve: {
    extensions: [".ts", ".tsx", ".js"],
    // web-bml's client/server sources live outside this package (in the
    // sibling ../web-bml submodule), so Node's default upward node_modules
    // walk from their directory never reaches ours - make it explicit.
    modules: [path.resolve(__dirname, "node_modules"), "node_modules"],
    fallback: {
      fs: false,
      path: false,
      url: false,
      vm: false,
      process: require.resolve("process/browser"),
      buffer: require.resolve("buffer"),
      stream: false,
      zlib: false,
      assert: false,
      util: false,
    },
  },
  // hidden-source-map emits the .map without the sourceMappingURL comment, so
  // WKWebView's inspector doesn't try (and fail, on file:// origin) to load it.
  devtool: "hidden-source-map",
  plugins: [
    new webpack.ProvidePlugin({
      process: "process/browser",
      Buffer: ["buffer", "Buffer"],
    }),
    new webpack.ProvidePlugin({
      acorn: path.resolve(__dirname, "../web-bml/JS-Interpreter", "acorn.js"),
    }),
  ],
};

if (process.env.NODE_ENV == null) {
  module.exports.mode = "development";
}
