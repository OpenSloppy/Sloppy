import React, { useState } from "react";
import { createRoot } from "react-dom/client";
import { ProviderEditor } from "./src/features/config/components/ProviderEditor";
import { PROVIDER_CATALOG_UI, getProviderDefinition, parseConfigList, providerIsConfigured } from "./src/features/config/configModel";
import "./src/styles/index.css";

function Preview() {
  const meta = getProviderDefinition("sloppy");
  const [form, setForm] = useState({ ...meta.defaultEntry });
  const [status, setStatus] = useState("");
  const [models, setModels] = useState<any[]>([]);
  return <ProviderEditor providerCatalog={PROVIDER_CATALOG_UI} configuredProviderRows={[]} customModelsCount={0}
    openAIProviderStatus={{}} anthropicProviderStatus={{}} geminiProviderStatus={{}}
    providerModalMeta={meta} providerForm={form} modalActiveEntry={form} modelRelayNodes={[]}
    modelConsoleInstances={[{id:"00000000-0000-0000-0000-000000000001", name:"Home Mac (fixture)",status:"active",canInfer:true},
      {id:"00000000-0000-0000-0000-000000000002",name:"Other Mac (fixture)",status:"active",canInfer:false,message:"Approve Work Core device in Console for Read and Run agents."}]}
    modelConsoleStatus="" onReloadConsoleInstances={() => {}} providerModelStatus={{sloppy:status}} providerModelOptions={{sloppy:models}}
    onUpdateProviderForm={(field, value) => setForm(previous => ({...previous,[field]:value,apiKey:field === "apiUrl" && String(value).startsWith("sloppy-console:") ? "" : previous.apiKey}))}
    onTestProviderConnection={() => {setModels([{id:"claude-code:sonnet",title:"Claude Sonnet",contextWindow:"200K",capabilities:["tools"]}]);setStatus("Connected through Sloppy Console.");}}
    providerProbeTesting={{}} onSaveProvider={() => setStatus("Saved Console provider.")} onRemoveProvider={() => {}} onCloseProviderModal={() => {}}
    openCodeConfig={{enabled:false}} onUpdateOpenCodeConfig={() => {}} parseConfigList={parseConfigList} providerIsConfigured={providerIsConfigured}
    onOpenProviderAtIndex={() => {}} onAppendProvider={() => {}} />;
}
createRoot(document.getElementById("root")!).render(<div style={{maxWidth:1100,margin:"32px auto",padding:24}}><Preview /></div>);
