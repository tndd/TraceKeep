import {createContext,useContext} from 'react';
export const DataContext=createContext(null);
export const useData=()=>useContext(DataContext);
export const clock=(start,t)=>Number.isFinite(t)?new Date(start+t*60000).toLocaleTimeString('ja-JP',{hour:'2-digit',minute:'2-digit'}):'—';
export const precise=(start,t)=>Number.isFinite(t)?new Date(start+t*60000).toLocaleTimeString('ja-JP',{hour:'2-digit',minute:'2-digit',second:'2-digit'}):'—';
